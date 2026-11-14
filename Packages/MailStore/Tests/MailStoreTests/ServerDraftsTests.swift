import Foundation
import MailCore
import Testing
@testable import MailStore

/// 下書きをサーバーの下書きフォルダにも置く (T23b、US-14)。
/// いちばん大事なこと: このアプリが入れた下書き (Message-ID がちょうど同じもの) 以外は、決して消さない。
@Suite struct ServerDraftsTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")

    private func server() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Drafts", specialUse: .drafts)
        // 自分で書いた (ほかのメールソフトの) 下書き。これは消してはいけない
        await server.add(.init(uid: 1, date: now, subject: "自分の下書き", from: "me@yahoo.example",
                               messageID: "mine@other.example"), to: "Drafts")
        await server.setKeepsAppendedMessages(true)
        return server
    }

    private func setUp(_ server: FakeMailServer) async throws -> (ServerDrafts, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: yahoo, session: server)
        await server.clearCalls()
        let accounts = [yahoo]
        return (ServerDrafts(store: store, accounts: { accounts }, openSession: { _ in server }), store)
    }

    private func saved(_ id: UUID, subject: String, at seconds: TimeInterval = 0) -> SavedDraft {
        SavedDraft(
            id: id,
            content: DraftContent(accountID: AccountID("yahoo"), to: "田中 <t@example.com>", subject: subject, body: "本文"),
            savedAt: now.addingTimeInterval(seconds)
        )
    }

    @Test func uploadingPutsExactlyOneCopy() async throws {
        let server = await server()
        let (drafts, _) = try await setUp(server)
        let id = UUID()
        let expected = ServerDrafts.messageID(for: id, account: yahoo)

        try await drafts.upload(saved(id, subject: "1 回目"))
        try await drafts.upload(saved(id, subject: "2 回目", at: 10))

        let ids = await server.messageIDs(in: "Drafts")
        #expect(ids.sorted() == [expected, "mine@other.example"].sorted())
        let appended = await server.appended
        #expect(appended.count == 2)
        let last = try MIMEParser.parse(try #require(appended.last?.data))
        #expect(last.subject == "2 回目")
        #expect(last.messageID == expected)
        // 入れ直す順番: 探す → 消す → 入れる。入れるときは「下書き」の印を付ける
        let calls = await server.calls.filter { !$0.hasPrefix("FETCH") && $0 != "CLOSE" }
        #expect(calls == [
            "SEARCH Drafts Message-ID \(ServerDrafts.marker(for: id))",
            "APPEND Drafts [\"\\\\Draft\", \"\\\\Seen\"]",
            "SEARCH Drafts Message-ID \(ServerDrafts.marker(for: id))",
            "DELETE Drafts [2]",
            "APPEND Drafts [\"\\\\Draft\", \"\\\\Seen\"]",
        ])
    }

    /// Gmail: 同期するのは「すべてのメール」などだけだが、下書きフォルダの名前は覚えておき、そこに置ける・消せる。
    /// (以前は名前を覚えていなかったので、Gmail には下書きが置かれなかった。2026-11-15 オーナーが見つけた)
    @Test func gmailDraftsGoToTheGmailDraftsFolder() async throws {
        let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.example", displayName: "Gmail")
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Drafts", specialUse: .drafts)
        await server.addFolder("[Gmail]/Spam", specialUse: .junk)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.add(.init(uid: 1, date: now, subject: "自分の下書き", from: "me@gmail.example",
                               messageID: "mine@other.example"), to: "[Gmail]/Drafts")
        await server.setKeepsAppendedMessages(true)
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: gmail, session: server)
        // 下書きフォルダの中身は同期しない (「すべてのメール」に入っているため)
        #expect(!(await server.calls).contains("EXAMINE [Gmail]/Drafts"))
        await server.clearCalls()
        let accounts = [gmail]
        let drafts = ServerDrafts(store: store, accounts: { accounts }, openSession: { _ in server })

        let id = UUID()
        let draft = SavedDraft(
            id: id, content: DraftContent(accountID: gmail.id, to: "t@example.com", subject: "Gmail の下書き", body: "本文"),
            savedAt: now
        )
        try await drafts.upload(draft)
        let expected = ServerDrafts.messageID(for: id, account: gmail)
        #expect(await server.messageIDs(in: "[Gmail]/Drafts").sorted() == [expected, "mine@other.example"].sorted())

        try await drafts.remove(id: id, accountID: gmail.id)
        #expect(await server.messageIDs(in: "[Gmail]/Drafts") == ["mine@other.example"])
    }

    /// 検索は「含む」で当たるので、似た Message-ID のメールも見つかる。中身を確かめて、ちょうど同じものだけを消す。
    @Test func lookAlikesAreNeverDeleted() async throws {
        let server = await server()
        let id = UUID()
        let marker = ServerDrafts.marker(for: id)
        await server.add(.init(uid: 50, date: now, subject: "似ている", from: "x@example.com",
                               messageID: "\(marker)@someone-else.example"), to: "Drafts")
        await server.add(.init(uid: 51, date: now, subject: "似ている 2", from: "x@example.com",
                               messageID: "re-\(marker)@yahoo.example"), to: "Drafts")
        let (drafts, _) = try await setUp(server)

        try await drafts.upload(saved(id, subject: "下書き"))
        try await drafts.remove(id: id, accountID: AccountID("yahoo"))

        let ids = await server.messageIDs(in: "Drafts").sorted()
        #expect(ids == ["\(marker)@someone-else.example", "mine@other.example", "re-\(marker)@yahoo.example"].sorted())
    }

    @Test func removingDeletesOnlyOurCopy() async throws {
        let server = await server()
        let (drafts, _) = try await setUp(server)
        let id = UUID()
        try await drafts.upload(saved(id, subject: "下書き"))
        try await drafts.remove(id: id, accountID: AccountID("yahoo"))
        #expect(await server.messageIDs(in: "Drafts") == ["mine@other.example"])
        // もうないものを消しても、何もしない
        await server.clearCalls()
        try await drafts.remove(id: id, accountID: AccountID("yahoo"))
        let calls = await server.calls
        #expect(!calls.contains { $0.hasPrefix("DELETE") })
    }

    /// UIDPLUS がないサーバーには、入れも消しもしない (消せないと、書き直すたびに下書きが増えてしまうため)。
    @Test func withoutUIDPlusTheServerIsNotTouched() async throws {
        let server = await server()
        await server.setHasUIDPlus(false)
        let (drafts, _) = try await setUp(server)

        await #expect(throws: IMAPError.unsupported("UIDPLUS")) {
            try await drafts.upload(saved(UUID(), subject: "下書き"))
        }
        let calls = await server.calls
        #expect(!calls.contains { $0.hasPrefix("APPEND") || $0.hasPrefix("DELETE") })
        #expect(await server.messageIDs(in: "Drafts") == ["mine@other.example"])
    }

    @Test func withoutADraftsFolderNothingIsSent() async throws {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        let (drafts, _) = try await setUp(server)
        await #expect(throws: MailRepositoryError.noFolder(.drafts)) {
            try await drafts.upload(saved(UUID(), subject: "下書き"))
        }
        let calls = await server.calls
        #expect(!calls.contains { $0.hasPrefix("APPEND") || $0.hasPrefix("DELETE") || $0.hasPrefix("SEARCH") })
    }

    /// 差出人のアカウントが決まっていない下書きは、サーバーに置かない。
    @Test func draftsWithoutAnAccountStayOnTheMac() async throws {
        let server = await server()
        let (drafts, _) = try await setUp(server)
        var draft = saved(UUID(), subject: "下書き")
        draft.content.accountID = nil
        try await drafts.upload(draft)
        #expect(await server.calls.isEmpty)
    }

    /// 同期で戻ってきたサーバーの写しは、下書きフォルダに二重に出さない (Mac の下書きだけを出す)。
    @Test func theServerCopyIsNotListedTwice() async throws {
        let server = await server()
        let (drafts, store) = try await setUp(server)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerDrafts-\(UUID().uuidString)")
        let local = DraftStore(directory: directory)
        let id = UUID()
        let draft = saved(id, subject: "下書き")
        try await local.save(draft.content, id: id, at: draft.savedAt)
        try await drafts.upload(draft)
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: yahoo, session: server)

        let accounts = [yahoo]
        let repository = DraftsMergingRepository(
            base: LiveMailRepository(store: store, accounts: { accounts }, openSession: { _ in server }), drafts: local
        )
        let listed = try await repository.messages(in: .unified(.drafts), filter: .all)
        #expect(listed.map(\.subject).sorted() == ["下書き", "自分の下書き"])
        #expect(listed.contains { $0.id == LocalDraft.messageID(id) })
    }
}
