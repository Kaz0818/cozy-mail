import Foundation
import MailCore
import Testing
@testable import MailStore

/// 受信トレイをすべて既読にする。Mac に保存していない古い未読も、サーバーで既読にする
/// (2026-11-15 オーナーの依頼。一覧で全部選んで既読にしても、古い未読が残って未読数が減らなかったため)。
@Suite struct MarkInboxReadTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let other = Account(id: AccountID("other"), provider: .yahoo, emailAddress: "me@other.example", displayName: "Other")

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    /// 受信トレイ: 最近の未読 2 通 (保存される)・既読 1 通、1 年前の未読 2 通 (保存されない)。迷惑メールにも未読。
    private func server() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Junk", specialUse: .junk)
        await server.add(.init(uid: 1, date: daysAgo(400), subject: "古い未読 1", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 2, date: daysAgo(380), subject: "古い未読 2", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 3, date: daysAgo(2), subject: "最近の未読 1", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 4, date: daysAgo(1), subject: "最近の未読 2", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 5, date: daysAgo(1), subject: "既読", from: "a@example.com", flags: ["\\Seen"]), to: "INBOX")
        await server.add(.init(uid: 9, date: daysAgo(1), subject: "迷惑", from: "x@example.com"), to: "Junk")
        return server
    }

    private func setUp(
        _ servers: [AccountID: FakeMailServer], accounts: [Account]
    ) async throws -> (LiveMailRepository, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        let now = now
        for account in accounts {
            guard let server = servers[account.id] else { continue }
            _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
            await server.clearCalls()
        }
        let list = accounts
        let repository = LiveMailRepository(store: store, accounts: { list }, openSession: { id in
            guard let server = servers[id] else { throw MailRepositoryError.actionUnavailable }
            return server
        })
        return (repository, store)
    }

    private func unreadOnServer(_ server: FakeMailServer, _ folder: String) async -> [UInt32] {
        (await server.folders[folder]?.messages ?? []).filter { !$0.flags.contains("\\Seen") }.map(\.uid).sorted()
    }

    /// 古い未読もサーバーで既読になり、Mac の未読と未読数も 0 になる。受信トレイ以外は変えない。
    @Test func marksOldAndNewUnreadAsRead() async throws {
        let server = await server()
        let (repository, store) = try await setUp([yahoo.id: server], accounts: [yahoo])
        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 4)  // サーバーの数 (古い未読も入る)

        let marked = try await repository.markInboxRead(account: nil)
        #expect(marked == 4)
        #expect(await unreadOnServer(server, "INBOX").isEmpty)
        #expect(await unreadOnServer(server, "Junk") == [9])
        let calls = await server.calls
        #expect(calls.contains("STORE INBOX +\\Seen [1, 2, 3, 4]"))
        #expect(!calls.contains { $0.hasPrefix("STORE Junk") })

        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 0)
        #expect(try await repository.unreadCount(in: .unified(.unread)) == 0)
        let inbox = try await store.summaries(matching: MessageQuery(accounts: [yahoo.id], selection: .unified(.inbox)))
        #expect(!inbox.isEmpty && inbox.allSatisfy(\.isRead))
    }

    /// アカウントを選んでいるときは、そのアカウントだけ。統合受信トレイ (nil) なら全部。
    @Test func onlyTheChosenAccount() async throws {
        let first = await server()
        let second = await server()
        let (repository, _) = try await setUp([yahoo.id: first, other.id: second], accounts: [yahoo, other])

        #expect(try await repository.markInboxRead(account: other.id) == 4)
        #expect(await unreadOnServer(first, "INBOX") == [1, 2, 3, 4])
        #expect(await unreadOnServer(second, "INBOX").isEmpty)
        #expect(try await repository.unreadCount(in: .account(yahoo.id, .inbox)) == 4)
        #expect(try await repository.unreadCount(in: .account(other.id, .inbox)) == 0)

        #expect(try await repository.markInboxRead(account: nil) == 4)
        #expect(await unreadOnServer(first, "INBOX").isEmpty)
    }

    /// 未読がなければ、印を付けに行かない。
    @Test func nothingUnreadSendsNoStore() async throws {
        let server = await server()
        let (repository, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        _ = try await repository.markInboxRead(account: nil)
        await server.clearCalls()
        #expect(try await repository.markInboxRead(account: nil) == 0)
        #expect(!(await server.calls).contains { $0.hasPrefix("STORE") })
    }

    /// サーバーが断ったら、Mac 側は変えずに失敗を知らせる (未読のまま)。
    @Test func aRejectedWriteChangesNothingOnTheMac() async throws {
        let server = await server()
        let (repository, store) = try await setUp([yahoo.id: server], accounts: [yahoo])
        await server.setFailNextWrite(true)
        await #expect(throws: FakeServerError.writeRejected) {
            _ = try await repository.markInboxRead(account: nil)
        }
        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 4)
        let inbox = try await store.summaries(matching: MessageQuery(accounts: [yahoo.id], selection: .unified(.inbox)))
        #expect(inbox.filter { !$0.isRead }.count == 2)
    }

    /// つながらないアカウントがあっても、ほかは既読にしてから、失敗を知らせる。
    @Test func oneFailingAccountDoesNotStopTheOthers() async throws {
        let server = await server()
        let (repository, _) = try await setUp([yahoo.id: server], accounts: [other, yahoo])
        await #expect(throws: MailRepositoryError.actionUnavailable) {
            _ = try await repository.markInboxRead(account: nil)
        }
        #expect(await unreadOnServer(server, "INBOX").isEmpty)
    }

    /// アプリでは、サーバー検索 (T27) と下書き (T23a) の窓口が外側にある。そこを通しても届く。
    @Test func worksThroughTheOuterRepositories() async throws {
        let server = await server()
        let (live, store) = try await setUp([yahoo.id: server], accounts: [yahoo])
        let accounts = [yahoo]
        let searching = ServerSearchRepository(
            base: live, store: store, accounts: { accounts }, openSession: { _ in server }, cache: ServerSearchCache()
        )
        let drafts = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MIR-\(UUID().uuidString)"))
        let outer = DraftsMergingRepository(base: searching, drafts: drafts)
        #expect(try await outer.markInboxRead(account: nil) == 4)
        #expect(await unreadOnServer(server, "INBOX").isEmpty)
    }
}
