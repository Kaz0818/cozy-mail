import Foundation
import MailCore
import Testing
@testable import MailStore

/// Mac に保存する保存先 (T10)。「保存 → 閉じる → 開き直す」で同じメールが出ること。
@Suite struct FileMessageStoreTests {
    private let yahoo = AccountID("yahoo")
    private let gmail = AccountID("gmail")
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// テストごとに空のフォルダを作る。終わったら `remove` で消す。
    private final class Folder {
        let url: URL

        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("FileMessageStoreTests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Mail", isDirectory: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    private func message(_ uid: UInt32, account: AccountID, mailbox: String = "INBOX", subject: String = "件名") -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID("\(account.rawValue)/\(mailbox)/\(uid)"),
                accountID: account,
                mailbox: mailbox == "INBOX" ? .inbox : .sent,
                sender: Contact(name: "田中 健一", address: "k.tanaka@example.com"),
                recipients: [Contact(name: "", address: "me@example.com")],
                subject: subject,
                preview: "こんにちは",
                date: now.addingTimeInterval(TimeInterval(uid)),
                isRead: uid.isMultiple(of: 2),
                isStarred: uid == 3,
                isFlagged: uid == 3,
                hasAttachments: uid == 1
            ),
            mailbox: mailbox,
            uid: uid,
            gmailMessageID: account == gmail ? UInt64(uid) * 1000 : nil,
            gmailThreadID: account == gmail ? 42 : nil,
            labels: account == gmail ? ["\\Inbox", "仕事"] : []
        )
    }

    @Test func everythingSurvivesReopening() async throws {
        let folder = Folder()
        let first = try open(folder)
        let messages = [message(1, account: yahoo), message(2, account: yahoo), message(3, account: gmail, mailbox: "[Gmail]/All Mail")]
        try await first.upsert(messages)
        try await first.setSyncState(MailboxSyncState(uidValidity: 7, highestUID: 2), account: yahoo, mailbox: "INBOX")
        try await first.setInboxUnreadCount(12, account: yahoo)
        try await first.setMailboxNames([.trash: "Trash", .sent: "Sent"], account: yahoo)
        try await first.setRawMessage(Data("raw 1".utf8), for: messages[0].summary.id)

        // 開き直す (アプリを終了して、また起動したのと同じ)
        let second = try open(folder)

        #expect(Set(try await second.allSummaries()) == Set(messages.map(\.summary)))
        #expect(try await second.message(id: messages[2].summary.id) == messages[2])
        #expect(Set(try await second.messages(account: yahoo, mailbox: "INBOX")) == Set(messages[0 ... 1]))
        #expect(try await second.syncState(account: yahoo, mailbox: "INBOX") == MailboxSyncState(uidValidity: 7, highestUID: 2))
        #expect(try await second.inboxUnreadCount(account: yahoo) == 12)
        #expect(try await second.inboxUnreadCount(account: gmail) == nil)
        #expect(try await second.mailboxName(for: .trash, account: yahoo) == "Trash")
        #expect(try await second.rawMessage(for: messages[0].summary.id) == Data("raw 1".utf8))
        #expect(try await second.rawMessage(for: messages[1].summary.id) == nil)
    }

    @Test func updatesReplaceTheSavedMessage() async throws {
        let folder = Folder()
        let store = try open(folder)
        var original = message(1, account: yahoo)
        try await store.upsert([original])
        original.summary.isRead.toggle()
        original.summary.isStarred = true
        try await store.upsert([original])

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries() == [original.summary])
    }

    @Test func deletedMessagesAndTheirBodiesStayDeleted() async throws {
        let folder = Folder()
        let store = try open(folder)
        let messages = [message(1, account: yahoo), message(2, account: yahoo)]
        try await store.upsert(messages)
        try await store.setRawMessage(Data("raw 1".utf8), for: messages[0].summary.id)
        try await store.setRawMessage(Data("raw 2".utf8), for: messages[1].summary.id)

        try await store.delete(account: yahoo, mailbox: "INBOX", uids: [1])

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries() == [messages[1].summary])
        #expect(try await reopened.rawMessage(for: messages[0].summary.id) == nil)
        #expect(try await reopened.rawMessage(for: messages[1].summary.id) == Data("raw 2".utf8))
        // 消したメールの本文のファイルは残らない
        #expect(try rawFileCount(in: folder.url) == 1)
    }

    @Test func deleteAllForgetsTheFolderAndItsSyncState() async throws {
        let folder = Folder()
        let store = try open(folder)
        try await store.upsert([message(1, account: yahoo), message(2, account: yahoo, mailbox: "Sent")])
        try await store.setSyncState(MailboxSyncState(uidValidity: 1, highestUID: 1), account: yahoo, mailbox: "INBOX")
        try await store.setSyncState(MailboxSyncState(uidValidity: 1, highestUID: 2), account: yahoo, mailbox: "Sent")

        try await store.deleteAll(account: yahoo, mailbox: "INBOX")

        let reopened = try open(folder)
        #expect(try await reopened.messages(account: yahoo, mailbox: "INBOX").isEmpty)
        #expect(try await reopened.syncState(account: yahoo, mailbox: "INBOX") == nil)
        #expect(try await reopened.messages(account: yahoo, mailbox: "Sent").count == 1)
        #expect(try await reopened.syncState(account: yahoo, mailbox: "Sent") != nil)
    }

    /// アカウントを削除したら、そのアカウントのファイルは全部消える。ほかのアカウントは残る。
    @Test func removingAnAccountDeletesItsFiles() async throws {
        let folder = Folder()
        let store = try open(folder)
        try await store.upsert([message(1, account: yahoo), message(2, account: gmail)])
        try await store.setRawMessage(Data("raw".utf8), for: message(1, account: yahoo).summary.id)
        try await store.setSyncState(MailboxSyncState(uidValidity: 1, highestUID: 1), account: yahoo, mailbox: "INBOX")

        try await store.deleteAccount(yahoo)

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries().map(\.accountID) == [gmail])
        #expect(try await reopened.syncState(account: yahoo, mailbox: "INBOX") == nil)
        let accountFolders = try FileManager.default.contentsOfDirectory(atPath: folder.url.appendingPathComponent("accounts").path)
        #expect(accountFolders.count == 1)
    }

    /// 壊れたファイルがあっても、起動できなくならない (サーバーから取り直せばよい)。
    @Test func aBrokenFileIsDiscardedInsteadOfFailing() async throws {
        let folder = Folder()
        let store = try open(folder)
        try await store.upsert([message(1, account: yahoo), message(2, account: gmail)])
        let yahooIndex = try indexFiles(in: folder.url).first { try String(contentsOf: $0, encoding: .utf8).contains("yahoo") }
        try Data("{ broken".utf8).write(to: try #require(yahooIndex))

        let reopened = try open(folder)

        #expect(try await reopened.allSummaries().map(\.accountID) == [gmail])
        // そのあとも保存できる
        try await reopened.upsert([message(5, account: yahoo)])
        let again = try open(folder)
        #expect(try await again.allSummaries().count == 2)
    }

    /// 違う形式 (将来の版など) のファイルは読まずに捨てる。
    @Test func anUnknownFormatVersionIsDiscarded() async throws {
        let folder = Folder()
        let store = try open(folder)
        try await store.upsert([message(1, account: yahoo)])
        let index = try #require(try indexFiles(in: folder.url).first)
        let text = try String(contentsOf: index, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":999").utf8).write(to: index)

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries().isEmpty)
    }

    /// 自分だけが読めるフォルダにする (ほかのユーザーからメールが見えないように)。
    @Test func theFolderIsPrivate() throws {
        let folder = Folder()
        _ = try open(folder)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    /// 本文のファイル名は、メールの ID にどんな文字があっても安全な名前になる。
    @Test func oddIDsAreStoredSafely() async throws {
        let folder = Folder()
        let store = try open(folder)
        let id = MessageID("../../etc/パスワード/" + String(repeating: "x", count: 400))
        var odd = message(1, account: AccountID("../weird id/"))
        odd = StoredMessage(summary: MessageSummary(
            id: id, accountID: odd.summary.accountID, mailbox: .inbox, sender: odd.summary.sender,
            subject: "s", preview: "p", date: now
        ), mailbox: "INBOX", uid: 1)
        try await store.upsert([odd])
        try await store.setRawMessage(Data("raw".utf8), for: id)

        let reopened = try open(folder)
        #expect(try await reopened.rawMessage(for: id) == Data("raw".utf8))
        // すべて保存先のフォルダの中にある
        let parent = folder.url.deletingLastPathComponent()
        let outside = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(outside == ["Mail"])
    }

    /// 同期して保存 → 開き直して同期すると、新しいメールだけを受信する (起動が速くなる)。
    @Test func afterReopeningOnlyNewMailIsFetched() async throws {
        let folder = Folder()
        let account = Account(id: yahoo, provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.add(.init(uid: 11, date: now.addingTimeInterval(-3600), subject: "one", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 12, date: now.addingTimeInterval(-1800), subject: "two", from: "b@example.com"), to: "INBOX")
        let now = now
        _ = try await SyncEngine(store: try open(folder), now: { now }).sync(account: account, session: server)

        await server.add(.init(uid: 13, date: now, subject: "three", from: "c@example.com"), to: "INBOX")
        await server.clearCalls()
        let reopened = try open(folder)
        // 受信する前から、前回の分が見える
        #expect(try await reopened.messages(account: yahoo, mailbox: "INBOX").count == 2)

        let report = try await SyncEngine(store: reopened, now: { now }).sync(account: account, session: server)

        #expect(report.added == 1)
        let calls = await server.calls
        #expect(calls.contains("FETCH INBOX 13:*"))
        #expect(!calls.contains("SEARCH INBOX"))
        #expect(try await reopened.messages(account: yahoo, mailbox: "INBOX").map(\.summary.subject).sorted() == ["one", "three", "two"])
    }

    // MARK: - 補助

    /// アプリと同じく、`MessageStore` として使う。
    private func open(_ folder: Folder) throws -> any MessageStore {
        try FileMessageStore(directory: folder.url)
    }

    private func indexFiles(in root: URL) throws -> [URL] {
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("index.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func rawFileCount(in root: URL) throws -> Int {
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil).reduce(0) { count, account in
            let raw = account.appendingPathComponent("raw", isDirectory: true)
            return count + ((try? FileManager.default.contentsOfDirectory(atPath: raw.path).count) ?? 0)
        }
    }
}
