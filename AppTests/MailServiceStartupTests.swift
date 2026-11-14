import AccountKit
import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 「キーチェーンを使おうとしています」の確認に答えるまで、パスワードを返さない保存場所。
/// アプリを作り直すたびに macOS が聞いてくるのと同じ状態を作る。
private final class WaitingSecretStore: SecretStore, @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waiting = false

    var isWaiting: Bool { lock.withLock { waiting } }

    func data(for key: String) throws -> Data? {
        lock.withLock { waiting = true }
        gate.wait()
        return Data("password".utf8)
    }

    func set(_ data: Data?, for key: String) throws {}

    /// 確認に「許可」と答えたのと同じ。
    func answer() {
        gate.signal()
    }
}

/// `MailAccountSettings` と同じ形 (アカウント一覧の保存形式)。
private struct SavedAccount: Encodable {
    var account: Account
    var imap: ServerSettings
    var smtp: ServerSettings
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@MainActor @Suite struct MailServiceStartupTests {
    /// 起動して受信がキーチェーンの確認で止まっていても、保存してあるメールはすぐ一覧に出る (T10)。
    @Test func savedMailIsShownWhileTheKeychainPromptIsOpen() async throws {
        let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode([SavedAccount(
            account: account,
            imap: ServerSettings(host: "imap.example.com", port: 993),
            smtp: ServerSettings(host: "smtp.example.com", port: 465)
        )]))
        let store = InMemoryMessageStore()
        let saved = StoredMessage(
            summary: MessageSummary(
                id: MessageID("a/1"), accountID: account.id, mailbox: .inbox,
                sender: Contact(name: "差出人", address: "s@example.com"),
                subject: "前回受信したメール", preview: "", date: Date(timeIntervalSince1970: 1_794_000_000)
            ),
            mailbox: "INBOX", uid: 1
        )
        try await store.upsert([saved])
        let secrets = WaitingSecretStore()
        let directory = AccountDirectory(
            storage: storage, secrets: secrets,
            connector: { _, _ in throw CancellationError() },
            senderConnector: { _, _ in throw CancellationError() }
        )
        let service = MailService(directory: directory, store: store)

        // 起動 (アカウントを読み、受信を始める)。受信はキーチェーンの確認で止まる
        let startup = Task { await service.start() }
        while !secrets.isWaiting { try await Task.sleep(for: .milliseconds(10)) }

        // 画面と同じように一覧を取りに行く
        let repository = service.repository
        let finished = Flag()
        let listing = Task {
            defer { finished.set() }
            return try await repository.messages(in: .unified(.inbox), filter: .all)
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !finished.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let shownWhilePromptIsOpen = finished.isSet

        // 後片付け: 確認に答えて、止まっていた処理を最後まで進める
        secrets.answer()
        await startup.value

        #expect(shownWhilePromptIsOpen, "キーチェーンの確認に答えるまで、保存してあるメールが一覧に出なかった")
        #expect(try await listing.value.map(\.id) == [saved.summary.id])
    }

    /// 作成ウィンドウを開いたまま設定で差出人の名前を変えても、送るときは新しい名前を使う。
    @Test func aRepositoryTakenEarlierSeesAccountChanges() async throws {
        let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A", senderName: "前の名前")
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode([SavedAccount(
            account: account,
            imap: ServerSettings(host: "imap.example.com", port: 993),
            smtp: ServerSettings(host: "smtp.example.com", port: 465)
        )]))
        let directory = AccountDirectory(
            storage: storage, secrets: InMemorySecretStore(),
            connector: { _, _ in throw CancellationError() },
            senderConnector: { _, _ in throw CancellationError() }
        )
        let service = MailService(directory: directory, store: InMemoryMessageStore())
        await service.start()
        // 作成ウィンドウを開いたときに受け取るもの
        let repositoryOfOpenWindow = service.repository

        try await service.setSenderName("新しい名前", for: account.id)

        #expect(try await repositoryOfOpenWindow.accounts().map(\.senderName) == ["新しい名前"])
    }
}
