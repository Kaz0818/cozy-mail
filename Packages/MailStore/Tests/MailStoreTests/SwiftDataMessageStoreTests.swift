// SwiftData は Apple 専用なので、Linux ではこのファイルは空になる (Mac の `xcodebuild test` で動く)。
#if canImport(SwiftData)
import Foundation
import MailCore
import Testing
@testable import MailStore
@testable import MailStoreSwiftData

/// Mac に保存する保存先 (T10)。「保存 → 閉じる → 開き直す」で同じメールが出ること。
@Suite struct SwiftDataMessageStoreTests {
    private let yahoo = AccountID("yahoo")
    private let gmail = AccountID("gmail")
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// テストごとに空のフォルダを作る。終わったら消す。
    private final class Folder {
        let root: URL
        var url: URL { root.appendingPathComponent("Mail", isDirectory: true) }

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftDataMessageStoreTests-\(UUID().uuidString)", isDirectory: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func message(_ uid: UInt32, account: AccountID, mailbox: String = "INBOX", subject: String = "件名") -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID("\(account.rawValue)/\(mailbox)/\(uid)"),
                accountID: account,
                mailbox: mailbox == "INBOX" ? .inbox : .sent,
                sender: Contact(name: "田中 健一", address: "k.tanaka@example.com"),
                recipients: [Contact(name: "", address: "me@example.com"), Contact(name: "山田 さくら", address: "s@example.com")],
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
        #expect(try await second.mailboxName(for: .junk, account: yahoo) == nil)
        #expect(try await second.rawMessage(for: messages[0].summary.id) == Data("raw 1".utf8))
        #expect(try await second.rawMessage(for: messages[1].summary.id) == nil)
    }

    /// Gmail の ID は 64 ビットの符号なし整数。大きい値も欠けずに戻る。
    @Test func largeGmailIDsRoundTrip() async throws {
        let folder = Folder()
        let store = try open(folder)
        var big = message(1, account: gmail)
        big.gmailMessageID = UInt64.max
        big.gmailThreadID = UInt64(Int64.max) + 5
        try await store.upsert([big])

        let reopened = try open(folder)
        #expect(try await reopened.message(id: big.summary.id) == big)
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
        // 消したメールの本文は、あとから同じ ID で入れ直しても戻ってこない
        try await reopened.upsert([messages[0]])
        #expect(try await reopened.rawMessage(for: messages[0].summary.id) == nil)
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

    /// アカウントを削除したら、そのアカウントのものは全部消える。ほかのアカウントは残る。
    @Test func removingAnAccountDeletesItsData() async throws {
        let folder = Folder()
        let store = try open(folder)
        let yahooMessage = message(1, account: yahoo)
        let gmailMessage = message(2, account: gmail)
        try await store.upsert([yahooMessage, gmailMessage])
        try await store.setRawMessage(Data("yahoo raw".utf8), for: yahooMessage.summary.id)
        try await store.setRawMessage(Data("gmail raw".utf8), for: gmailMessage.summary.id)
        try await store.setSyncState(MailboxSyncState(uidValidity: 1, highestUID: 1), account: yahoo, mailbox: "INBOX")
        try await store.setInboxUnreadCount(3, account: yahoo)
        try await store.setMailboxNames([.trash: "Trash"], account: yahoo)
        try await store.setInboxUnreadCount(4, account: gmail)

        try await store.deleteAccount(yahoo)

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries().map(\.accountID) == [gmail])
        #expect(try await reopened.syncState(account: yahoo, mailbox: "INBOX") == nil)
        #expect(try await reopened.inboxUnreadCount(account: yahoo) == nil)
        #expect(try await reopened.mailboxName(for: .trash, account: yahoo) == nil)
        #expect(try await reopened.rawMessage(for: yahooMessage.summary.id) == nil)
        #expect(try await reopened.rawMessage(for: gmailMessage.summary.id) == Data("gmail raw".utf8))
        #expect(try await reopened.inboxUnreadCount(account: gmail) == 4)
    }

    /// 読めない保存ファイルは、黙って壊さず、開けないと知らせる (アプリはメモリ上の保存先に切り替える)。
    @Test func anUnreadableStoreThrowsInsteadOfCrashing() throws {
        let folder = Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("これは SwiftData のファイルではない".utf8).write(to: folder.url.appendingPathComponent(SwiftDataMessageStore.fileName))

        #expect(throws: (any Error).self) { try open(folder) }
    }

    /// 自分だけが読めるフォルダにする (ほかのユーザーからメールが見えないように)。
    @Test func theFolderIsPrivate() throws {
        let folder = Folder()
        _ = try open(folder)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    /// ID やフォルダ名にどんな文字があっても、そのまま保存して取り出せ、保存先の外には何も作らない。
    @Test func oddIDsAreStoredSafely() async throws {
        let folder = Folder()
        let store = try open(folder)
        let id = MessageID("../../etc/パスワード/" + String(repeating: "x", count: 400))
        let weirdAccount = AccountID("../weird id/'; DROP TABLE --")
        let odd = StoredMessage(summary: MessageSummary(
            id: id, accountID: weirdAccount, mailbox: .inbox, sender: Contact(name: "", address: "a@example.com"),
            subject: "s", preview: "p", date: now
        ), mailbox: "INBOX/日本語 フォルダ", uid: 1)
        try await store.upsert([odd])
        try await store.setRawMessage(Data("raw".utf8), for: id)

        let reopened = try open(folder)
        #expect(try await reopened.rawMessage(for: id) == Data("raw".utf8))
        #expect(try await reopened.messages(account: weirdAccount, mailbox: "INBOX/日本語 フォルダ") == [odd])
        let outside = try FileManager.default.contentsOfDirectory(atPath: folder.root.path)
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

    // MARK: - 開き直さずに続けて使う (アプリが動いている間)

    /// 1 回の保存に同じ ID が 2 通あっても失敗せず、あとのほうが残る (メモリ上の保存先と同じ)。
    @Test func duplicateIDsInOneUpsertKeepTheLastOne() async throws {
        let folder = Folder()
        let store = try open(folder)
        let first = message(1, account: yahoo, subject: "前")
        var second = first
        second.summary.subject = "後"

        try await store.upsert([first, second])

        #expect(try await store.allSummaries() == [second.summary])
        let reopened = try open(folder)
        #expect(try await reopened.allSummaries() == [second.summary])
    }

    /// 消したあと、同じ保存先のまま続けて使っても、消したものが見えたり、保存し直せなくなったりしない。
    @Test func deletingThenReusingTheSameStoreWorks() async throws {
        let folder = Folder()
        let store = try open(folder)
        let item = message(1, account: yahoo)
        try await store.upsert([item])
        try await store.setRawMessage(Data("raw".utf8), for: item.summary.id)
        try await store.setInboxUnreadCount(5, account: yahoo)
        try await store.setMailboxNames([.trash: "Trash"], account: yahoo)
        try await store.setSyncState(MailboxSyncState(uidValidity: 1, highestUID: 1), account: yahoo, mailbox: "INBOX")
        // 一度読んでおく (読み込んだものが残っていても、消したあとに見えないこと)
        _ = try await store.rawMessage(for: item.summary.id)
        _ = try await store.inboxUnreadCount(account: yahoo)
        _ = try await store.syncState(account: yahoo, mailbox: "INBOX")

        try await store.deleteAccount(yahoo)

        #expect(try await store.allSummaries().isEmpty)
        #expect(try await store.rawMessage(for: item.summary.id) == nil)
        #expect(try await store.inboxUnreadCount(account: yahoo) == nil)
        #expect(try await store.mailboxName(for: .trash, account: yahoo) == nil)
        #expect(try await store.syncState(account: yahoo, mailbox: "INBOX") == nil)

        // 同じアカウントを追加し直して、また保存できる
        try await store.upsert([item])
        try await store.setRawMessage(Data("raw 2".utf8), for: item.summary.id)
        try await store.setInboxUnreadCount(7, account: yahoo)
        try await store.setMailboxNames([.sent: "Sent"], account: yahoo)
        try await store.setSyncState(MailboxSyncState(uidValidity: 2, highestUID: 9), account: yahoo, mailbox: "INBOX")

        let reopened = try open(folder)
        #expect(try await reopened.allSummaries() == [item.summary])
        #expect(try await reopened.rawMessage(for: item.summary.id) == Data("raw 2".utf8))
        #expect(try await reopened.inboxUnreadCount(account: yahoo) == 7)
        #expect(try await reopened.mailboxName(for: .sent, account: yahoo) == "Sent")
        #expect(try await reopened.mailboxName(for: .trash, account: yahoo) == nil)
        #expect(try await reopened.syncState(account: yahoo, mailbox: "INBOX") == MailboxSyncState(uidValidity: 2, highestUID: 9))
    }

    /// `UIDVALIDITY` が変わって取り直すとき: フォルダを消して、すぐ同じ UID で入れ直しても正しく残る。
    @Test func deleteAllThenRefillTheSameFolder() async throws {
        let folder = Folder()
        let store = try open(folder)
        let old = message(1, account: yahoo, subject: "古い")
        try await store.upsert([old])
        try await store.setRawMessage(Data("old raw".utf8), for: old.summary.id)
        _ = try await store.messages(account: yahoo, mailbox: "INBOX")

        try await store.deleteAll(account: yahoo, mailbox: "INBOX")
        var refilled = old
        refilled.summary.subject = "新しい"
        try await store.upsert([refilled])

        #expect(try await store.messages(account: yahoo, mailbox: "INBOX") == [refilled])
        #expect(try await store.rawMessage(for: old.summary.id) == nil)
        let reopened = try open(folder)
        #expect(try await reopened.messages(account: yahoo, mailbox: "INBOX") == [refilled])
        #expect(try await reopened.rawMessage(for: old.summary.id) == nil)
    }

    // MARK: - 何年分も置ける

    /// 5 年分 (3 アカウント・約 6,000 通) を保存して開き直しても、フォルダごとの取り出しと数が合う。
    @Test func yearsOfMailStayQueryable() async throws {
        let folder = Folder()
        let store = try open(folder)
        let accounts = [yahoo, gmail, AccountID("icloud")]
        var all: [StoredMessage] = []
        for account in accounts {
            for uid in UInt32(1) ... 2000 {
                var item = message(uid, account: account)
                // 約 5 年にわたって散らす
                item.summary.date = now.addingTimeInterval(-Double(uid) * 5 * 86400 / 2000 * 365)
                all.append(item)
            }
        }
        // 同期は少しずつ書き込む。まとめて入れるのと同じ結果になる
        for chunk in stride(from: 0, to: all.count, by: 500) {
            try await store.upsert(Array(all[chunk ..< min(chunk + 500, all.count)]))
        }

        let reopened = try open(folder)
        let start = Date()
        #expect(try await reopened.messages(account: yahoo, mailbox: "INBOX").count == 2000)
        #expect(try await reopened.allSummaries().count == 6000)
        #expect(try await reopened.message(id: MessageID("gmail/INBOX/1500"))?.uid == 1500)
        // 6,000 通の取り出しが数秒以内 (目安。遅くなったら索引を疑う)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    /// 添付つきの大きいメール (数 MB) も、そのまま保存して取り出せる。
    @Test func largeRawMessagesRoundTrip() async throws {
        let folder = Folder()
        let store = try open(folder)
        let item = message(1, account: yahoo)
        let big = Data((0 ..< 8 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await store.upsert([item])
        try await store.setRawMessage(big, for: item.summary.id)
        // 上書きできる
        try await store.setRawMessage(big + [1], for: item.summary.id)

        let reopened = try open(folder)
        #expect(try await reopened.rawMessage(for: item.summary.id) == big + [1])
    }

    /// 大きい本文はデータベースの外のファイルになる。メールやアカウントを消したら、そのファイルもディスクから消える。
    @Test func deletingRemovesBodyFilesFromDisk() async throws {
        let folder = Folder()
        let store = try open(folder)
        let big = Data((0 ..< 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let messages = [message(1, account: yahoo), message(2, account: yahoo), message(3, account: gmail)]
        try await store.upsert(messages)
        for item in messages {
            try await store.setRawMessage(big + Data(item.summary.id.rawValue.utf8), for: item.summary.id)
        }
        #expect(try externalFileCount(in: folder.url) == 3)

        try await store.delete(account: yahoo, mailbox: "INBOX", uids: [1])
        #expect(try externalFileCount(in: folder.url) == 2)

        try await store.deleteAccount(yahoo)
        #expect(try externalFileCount(in: folder.url) == 1)

        // 本文を上書きしても、古いファイルは残らない
        try await store.setRawMessage(big + [9], for: messages[2].summary.id)
        #expect(try externalFileCount(in: folder.url) == 1)
        #expect(try await open(folder).rawMessage(for: messages[2].summary.id) == big + [9])
    }

    // MARK: - 補助

    /// SwiftData がデータベースの外に置いたファイルの数。
    private func externalFileCount(in directory: URL) throws -> Int {
        let external = directory.appendingPathComponent(".Mail_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        guard FileManager.default.fileExists(atPath: external.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(atPath: external.path).count
    }

    /// アプリと同じく、`MessageStore` として使う。
    private func open(_ folder: Folder) throws -> any MessageStore {
        try SwiftDataMessageStore(directory: folder.url)
    }
}
#endif
