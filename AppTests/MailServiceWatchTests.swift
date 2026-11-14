import AccountKit
import Foundation
import MailCore
import MailStore
import Testing
@testable import CozyMail

/// 新着の見張り (T20a) と、アカウントごとの同期のまとめ方。本物のサーバーには触れない。
@MainActor @Suite struct MailServiceWatchTests {
    /// 同期の回数と、同時に走った数を数える偽の接続。IDLE は台本どおりに知らせを返す。
    actor CountingSession: MailServerSession {
        private var idleEvents: [IMAPIdleEvent]
        private(set) var syncs = 0
        private(set) var running = 0
        private(set) var maxRunning = 0
        private let syncDelay: Duration

        init(idleEvents: [IMAPIdleEvent] = [], syncDelay: Duration = .zero) {
            self.idleEvents = idleEvents
            self.syncDelay = syncDelay
        }

        func supportsIdle() async throws -> Bool { true }

        func idle(in mailbox: String, timeout: Duration) async throws -> IMAPIdleEvent {
            if !idleEvents.isEmpty { return idleEvents.removeFirst() }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .cancelled
        }

        // 同期の始まり (SyncEngine は最初にフォルダの一覧を取る)
        func listMailboxes() async throws -> [IMAPMailbox] {
            syncs += 1
            running += 1
            maxRunning = max(maxRunning, running)
            if syncDelay > .zero { try? await Task.sleep(for: syncDelay) }
            running -= 1
            return []
        }

        func examine(_ mailbox: String) async throws -> IMAPMailboxStatus { throw IMAPError.connectionClosed }
        func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] { [] }
        func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func unreadCount(of mailbox: String) async throws -> Int { 0 }
        func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data { Data() }
        func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func move(uids: [UInt32], from mailbox: String, to target: String) async throws {}
        func append(_ message: Data, to mailbox: String, flags: [String]) async throws {}
        func close() async {}
    }

    private struct SavedAccount: Encodable {
        var account: Account
        var imap: ServerSettings
        var smtp: ServerSettings
    }

    private let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")

    private func service(session: CountingSession, watching: Bool) throws -> MailService {
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode([SavedAccount(
            account: account,
            imap: ServerSettings(host: "imap.example.com", port: 993),
            smtp: ServerSettings(host: "smtp.example.com", port: 465)
        )]))
        let secrets = InMemorySecretStore()
        try secrets.set(Data("pw".utf8), for: "password.a")
        let directory = AccountDirectory(
            storage: storage, secrets: secrets,
            connector: { _, _ in session },
            senderConnector: { _, _ in throw CancellationError() }
        )
        return MailService(directory: directory, store: InMemoryMessageStore(), watchesForNewMail: watching)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aChangeOnTheServerSyncsThatAccount() async throws {
        let session = CountingSession(idleEvents: [.changed])
        let service = try service(session: session, watching: true)
        await service.start()
        // 起動の同期 1 回 + 知らせによる同期 1 回
        await waitUntil { await session.syncs >= 2 }
        #expect(await session.syncs == 2)
        service.stopWatching()
    }

    /// テストや見本では、見張らない (本物のサーバーにつながないため)。
    @Test func doesNotWatchUnlessAskedTo() async throws {
        let session = CountingSession(idleEvents: [.changed])
        let service = try service(session: session, watching: false)
        await service.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.syncs == 1)
    }

    /// 同期中にもう一度頼まれたら、同時には走らせず、終わってからもう 1 回だけ同期する (新着を取りこぼさない)。
    @Test func aSyncRequestedDuringASyncRunsOnceMoreAfterwards() async throws {
        let session = CountingSession(syncDelay: .milliseconds(100))
        let service = try service(session: session, watching: false)
        await service.start()
        #expect(await session.syncs == 1)
        async let first: Void = service.sync(accountID: account.id)
        async let second: Void = service.sync(accountID: account.id)
        async let third: Void = service.sync(accountID: account.id)
        _ = await (first, second, third)
        #expect(await session.syncs == 3)
        #expect(await session.maxRunning == 1)
    }
}
