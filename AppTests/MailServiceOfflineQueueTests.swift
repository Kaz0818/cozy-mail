import AccountKit
import Foundation
import MailCore
import MailStore
import Testing
@testable import CozyMail

/// オフラインの待ち行列 (T22)。同期の前に、ためた操作を送る。本物のサーバーには触れない。
@MainActor @Suite struct MailServiceOfflineQueueTests {
    /// 呼ばれた順を記録する偽の接続。`offline` なら、書き込みで接続が切れる。
    actor RecordingSession: MailServerSession {
        private(set) var calls: [String] = []
        private let offline: Bool

        init(offline: Bool = false) {
            self.offline = offline
        }

        // 同期の始まり (SyncEngine は最初にフォルダの一覧を取る)
        func listMailboxes() async throws -> [IMAPMailbox] {
            calls.append("SYNC")
            return []
        }

        func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {
            if offline { throw IMAPError.connectionClosed }
            calls.append("STORE \(mailbox) \(add ? "+" : "-")\(flags.joined(separator: " ")) \(uids)")
        }

        func examine(_ mailbox: String) async throws -> IMAPMailboxStatus { throw IMAPError.connectionClosed }
        func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] { [] }
        func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] { [] }
        func unreadCount(of mailbox: String) async throws -> Int { 0 }
        func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data { Data() }
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

    private let account = Account(id: AccountID("a"), provider: .yahoo, emailAddress: "a@yahoo.example", displayName: "A")

    private func service(session: RecordingSession, queue: PendingActionQueue) throws -> MailService {
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
        return MailService(directory: directory, store: InMemoryMessageStore(), pendingActions: queue)
    }

    private func queue(with uids: [UInt32]) async throws -> PendingActionQueue {
        let queue = PendingActionQueue(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("OfflineQueueTests-\(UUID().uuidString).json")
        )
        for uid in uids {
            try await queue.append(PendingAction(
                accountID: account.id, action: .markRead, mailbox: "INBOX", uids: [uid], destination: nil, gmail: false,
                queuedAt: Date()
            ))
        }
        return queue
    }

    @Test func queuedActionsAreSentBeforeSyncing() async throws {
        let session = RecordingSession()
        let queue = try await queue(with: [1, 2])
        let service = try service(session: session, queue: queue)

        await service.start()

        #expect(await session.calls == ["STORE INBOX +\\Seen [1]", "STORE INBOX +\\Seen [2]", "SYNC"])
        #expect(await queue.pending().isEmpty)
    }

    /// まだ送れないうちに同期すると、サーバーの古い状態で Mac の表示が戻るので、同期しない。
    @Test func doesNotSyncWhileActionsCannotBeSent() async throws {
        let session = RecordingSession(offline: true)
        let queue = try await queue(with: [1])
        let service = try service(session: session, queue: queue)

        await service.start()

        #expect(await session.calls.isEmpty)
        #expect(await queue.pending().count == 1)
        #expect(service.syncError != nil)
    }

    @Test func removingTheAccountDropsItsQueuedActions() async throws {
        let session = RecordingSession(offline: true)
        let queue = try await queue(with: [1])
        let service = try service(session: session, queue: queue)
        await service.start()

        await service.removeAccount(account.id)

        #expect(await queue.pending().isEmpty)
    }
}
