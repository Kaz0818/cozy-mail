import Foundation
import MailCore
import Testing
@testable import MailStore

/// オフラインの待ち行列 (T22、US-13)。つながらないときの整理の操作をためて、つながったら古い順に送る。
@Suite struct PendingActionsTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")

    /// つながるかどうかを切り替えられるネットワーク。
    private actor Network {
        var isOnline = true
        func set(online: Bool) { isOnline = online }
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingActionsTests-\(UUID().uuidString)")
            .appendingPathComponent("PendingActions.json")
    }

    private func yahooServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Trash", specialUse: .trash)
        await server.addFolder("Archive", specialUse: .archive)
        await server.add(.init(uid: 11, date: now.addingTimeInterval(-86400), subject: "unread", from: "a@example.com"), to: "INBOX")
        await server.add(
            .init(uid: 12, date: now.addingTimeInterval(-86400), subject: "read", from: "b@example.com", flags: ["\\Seen"]),
            to: "INBOX"
        )
        return server
    }

    private struct Setup {
        let repository: LiveMailRepository
        let store: InMemoryMessageStore
        let queue: PendingActionQueue
        let network: Network
    }

    /// 同期した保存先と、待ち行列を使うリポジトリ。`network` が切れていると、つなぐときに失敗する。
    private func setUp(account: Account, server: FakeMailServer, queue: PendingActionQueue? = nil) async throws -> Setup {
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
        let network = Network()
        let queue = queue ?? PendingActionQueue(fileURL: temporaryFile())
        let accounts = [account]
        let repository = LiveMailRepository(
            store: store, accounts: { accounts },
            openSession: { _ in
                guard await network.isOnline else { throw IMAPError.connectionFailed("offline") }
                return server
            },
            pendingActions: queue,
            now: { now }
        )
        return Setup(repository: repository, store: store, queue: queue, network: network)
    }

    private func message(_ store: InMemoryMessageStore, account: Account, mailbox: String, uid: UInt32) async throws -> StoredMessage {
        try #require(try await store.messages(account: account.id, mailbox: mailbox).first { $0.uid == uid })
    }

    // MARK: - ためる

    @Test func offlineActionKeepsTheChangeAndIsQueued() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let target = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        await s.network.set(online: false)
        await server.clearCalls()

        // 失敗にならず、Mac の表示は既読のまま
        try await s.repository.perform(.markRead, on: target.summary.id)

        #expect(try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11).summary.isRead)
        #expect(try await s.store.inboxUnreadCount(account: yahoo.id) == 0)
        #expect(await server.calls.isEmpty)
        let pending = await s.queue.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.action == .markRead)
        #expect(pending.first?.mailbox == "INBOX")
        #expect(pending.first?.uids == [11])
    }

    @Test func offlineMoveIsQueuedWithItsDestination() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let target = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        await s.network.set(online: false)

        try await s.repository.perform(.moveToTrash, on: target.summary.id)

        #expect(try await s.repository.messages(in: .unified(.trash), filter: .all).map(\.subject) == ["unread"])
        #expect(await s.queue.pending().first?.destination == "Trash")
    }

    @Test func offlineBulkActionIsQueuedAsOneServerRequest() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let first = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        let second = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 12)
        await s.network.set(online: false)

        try await s.repository.perform(.star, on: [first.summary.id, second.summary.id])

        let pending = await s.queue.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.uids == [11, 12])
    }

    // MARK: - 送る

    @Test func queuedActionsAreSentInOrderWhenOnlineAgain() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let first = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        let second = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 12)
        await s.network.set(online: false)
        try await s.repository.perform(.markRead, on: first.summary.id)
        try await s.repository.perform(.archive, on: second.summary.id)
        await server.clearCalls()

        await s.network.set(online: true)
        let result = try await s.queue.flush(account: yahoo.id, session: server)

        #expect(result == PendingActionQueue.FlushResult(sent: 2))
        #expect(await server.calls == ["STORE INBOX +\\Seen [11]", "MOVE INBOX -> Archive [12]"])
        #expect(await s.queue.pending().isEmpty)
    }

    @Test func newActionWaitsBehindQueuedOnesSoTheOrderIsKept() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let target = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        await s.network.set(online: false)
        try await s.repository.perform(.markRead, on: target.summary.id)
        await server.clearCalls()

        // つながったあとの操作は、前にためた操作のあとに送られる (既読 → 未読の順。逆だと既読のまま残る)
        await s.network.set(online: true)
        try await s.repository.perform(.markUnread, on: target.summary.id)

        #expect(await server.calls == ["STORE INBOX +\\Seen [11]", "STORE INBOX -\\Seen [11]"])
        #expect(await s.queue.pending().isEmpty)
        #expect(try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11).summary.isRead == false)
    }

    @Test func newActionIsQueuedTooWhileStillOffline() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let target = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        await s.network.set(online: false)

        try await s.repository.perform(.markRead, on: target.summary.id)
        try await s.repository.perform(.star, on: target.summary.id)

        #expect(await s.queue.pending().map(\.action) == [.markRead, .star])
    }

    @Test func refusedActionIsDroppedAndTheRestAreStillSent() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let first = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        let second = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 12)
        await s.network.set(online: false)
        try await s.repository.perform(.star, on: first.summary.id)
        try await s.repository.perform(.star, on: second.summary.id)

        // 1 つめはサーバーに断られる。あきらめて (表示は次の同期でサーバーに合う)、2 つめは送る
        await server.setFailNextWrite(true)
        let result = try await s.queue.flush(account: yahoo.id, session: server)

        #expect(result == PendingActionQueue.FlushResult(sent: 1, dropped: 1))
        #expect(await server.calls.contains("STORE INBOX +\\Flagged [12]"))
        #expect(await s.queue.pending().isEmpty)
    }

    @Test func flushStopsAndKeepsTheRestWhenTheConnectionDrops() async throws {
        let queue = PendingActionQueue(fileURL: temporaryFile())
        for uid: UInt32 in [1, 2] {
            try await queue.append(PendingAction(
                accountID: yahoo.id, action: .markRead, mailbox: "INBOX", uids: [uid], destination: nil, gmail: false, queuedAt: now
            ))
        }

        await #expect(throws: IMAPError.connectionClosed) {
            try await queue.flush(account: yahoo.id, session: DisconnectedSession())
        }
        #expect(await queue.pending().map(\.uids) == [[1], [2]])
    }

    @Test func gmailArchiveIsSentAsRemovingTheInboxLabel() async throws {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.add(
            .init(uid: 7, date: now.addingTimeInterval(-86400), subject: "hi", from: "a@example.com",
                  gmailMessageID: 101, labels: ["\\Inbox"]),
            to: "[Gmail]/All Mail"
        )
        let s = try await setUp(account: gmail, server: server)
        let target = try await message(s.store, account: gmail, mailbox: "[Gmail]/All Mail", uid: 7)
        await s.network.set(online: false)
        try await s.repository.perform(.archive, on: target.summary.id)
        await server.clearCalls()

        _ = try await s.queue.flush(account: gmail.id, session: server)

        #expect(await server.calls == ["LABELS [Gmail]/All Mail -\\Inbox [7]"])
    }

    // MARK: - 断られたとき (オフラインではない)

    @Test func serverRefusalStillRevertsAndThrows() async throws {
        let server = await yahooServer()
        let s = try await setUp(account: yahoo, server: server)
        let target = try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11)
        await server.setFailNextWrite(true)

        await #expect(throws: FakeServerError.writeRejected) {
            try await s.repository.perform(.markRead, on: target.summary.id)
        }
        #expect(try await message(s.store, account: yahoo, mailbox: "INBOX", uid: 11).summary.isRead == false)
        #expect(await s.queue.pending().isEmpty)
    }

    @Test func withoutAQueueOfflineStillRevertsAndThrows() async throws {
        let server = await yahooServer()
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: yahoo, session: server)
        let accounts = [yahoo]
        let repository = LiveMailRepository(
            store: store, accounts: { accounts },
            openSession: { _ in throw IMAPError.connectionFailed("offline") }
        )
        let target = try await message(store, account: yahoo, mailbox: "INBOX", uid: 11)

        await #expect(throws: IMAPError.connectionFailed("offline")) {
            try await repository.perform(.markRead, on: target.summary.id)
        }
        #expect(try await message(store, account: yahoo, mailbox: "INBOX", uid: 11).summary.isRead == false)
    }

    // MARK: - 保存

    @Test func queueSurvivesReopening() async throws {
        let file = temporaryFile()
        let queue = PendingActionQueue(fileURL: file)
        let action = PendingAction(
            accountID: yahoo.id, action: .moveToTrash, mailbox: "INBOX", uids: [3, 4], destination: "Trash", gmail: false,
            queuedAt: now
        )
        try await queue.append(action)

        // アプリを開き直したのと同じ
        let reopened = PendingActionQueue(fileURL: file)
        #expect(await reopened.pending() == [action])
    }

    @Test func brokenFileStartsEmpty() async throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("壊れた中身".utf8).write(to: file)

        #expect(await PendingActionQueue(fileURL: file).pending().isEmpty)
    }

    @Test func removingAnAccountDropsItsActions() async throws {
        let queue = PendingActionQueue(fileURL: temporaryFile())
        for account in [yahoo.id, gmail.id] {
            try await queue.append(PendingAction(
                accountID: account, action: .star, mailbox: "INBOX", uids: [1], destination: nil, gmail: false, queuedAt: now
            ))
        }

        try await queue.removeAll(account: yahoo.id)

        #expect(await queue.pending().map(\.accountID) == [gmail.id])
        #expect(await queue.hasPending(account: yahoo.id) == false)
    }

    // MARK: - 見分け方

    @Test func onlyConnectionProblemsCountAsOffline() {
        #expect(PendingAction.isOffline(IMAPError.connectionFailed("no route")))
        #expect(PendingAction.isOffline(IMAPError.connectionClosed))
        #expect(!PendingAction.isOffline(IMAPError.commandFailed("NO")))
        #expect(!PendingAction.isOffline(IMAPError.authenticationFailed("wrong")))
        #expect(!PendingAction.isOffline(FakeServerError.writeRejected))
    }
}

/// 書き込もうとすると、接続が切れる接続 (途中でオフラインになったとき)。
private struct DisconnectedSession: MailServerSession {
    func listMailboxes() async throws -> [IMAPMailbox] { throw IMAPError.connectionClosed }
    func examine(_ mailbox: String) async throws -> IMAPMailboxStatus { throw IMAPError.connectionClosed }
    func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] { throw IMAPError.connectionClosed }
    func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        throw IMAPError.connectionClosed
    }
    func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        throw IMAPError.connectionClosed
    }
    func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        throw IMAPError.connectionClosed
    }
    func unreadCount(of mailbox: String) async throws -> Int { throw IMAPError.connectionClosed }
    func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data { throw IMAPError.connectionClosed }
    func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws { throw IMAPError.connectionClosed }
    func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {
        throw IMAPError.connectionClosed
    }
    func move(uids: [UInt32], from mailbox: String, to target: String) async throws { throw IMAPError.connectionClosed }
    func append(_ message: Data, to mailbox: String, flags: [String]) async throws { throw IMAPError.connectionClosed }
    func close() async {}
    func idle(in mailbox: String, timeout: Duration) async throws -> IMAPIdleEvent { throw IMAPError.connectionClosed }
    func searchUIDs(in mailbox: String, header field: String, containing value: String) async throws -> [UInt32] {
        throw IMAPError.connectionClosed
    }
    func searchUIDs(in mailbox: String, text: String) async throws -> [UInt32] { throw IMAPError.connectionClosed }
    func supportsUIDPlus() async throws -> Bool { false }
    func deleteMessages(uids: [UInt32], in mailbox: String) async throws { throw IMAPError.connectionClosed }
    func searchUnreadUIDs(in mailbox: String) async throws -> [UInt32] { throw IMAPError.connectionClosed }
}
