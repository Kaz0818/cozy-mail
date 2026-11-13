import Foundation

/// Mac に保存した 1 通のメール。一覧に出す情報 (`summary`) と、サーバーと突き合わせるための情報。
public struct StoredMessage: Sendable, Hashable {
    public var summary: MessageSummary
    /// サーバー上のフォルダ名 (修正 UTF-7 のまま)。
    public var mailbox: String
    public var uid: UInt32
    public var gmailMessageID: UInt64?
    public var gmailThreadID: UInt64?
    public var labels: [String]

    public init(
        summary: MessageSummary,
        mailbox: String,
        uid: UInt32,
        gmailMessageID: UInt64? = nil,
        gmailThreadID: UInt64? = nil,
        labels: [String] = []
    ) {
        self.summary = summary
        self.mailbox = mailbox
        self.uid = uid
        self.gmailMessageID = gmailMessageID
        self.gmailThreadID = gmailThreadID
        self.labels = labels
    }
}

/// フォルダごとの同期の進み具合。`uidValidity` が変わったら、保存分は使えない (全部取り直す)。
public struct MailboxSyncState: Sendable, Hashable, Codable {
    public var uidValidity: UInt32
    /// ここまでの UID は取得済み。次はこれより大きい UID だけを取る。
    public var highestUID: UInt32

    public init(uidValidity: UInt32, highestUID: UInt32) {
        self.uidValidity = uidValidity
        self.highestUID = highestUID
    }
}

/// メールの保存先。アプリでは SwiftData (`MailStoreSwiftData`)、テストではメモリ上 (`InMemoryMessageStore`)。
public protocol MessageStore: Sendable {
    func syncState(account: AccountID, mailbox: String) async throws -> MailboxSyncState?
    func setSyncState(_ state: MailboxSyncState, account: AccountID, mailbox: String) async throws
    func messages(account: AccountID, mailbox: String) async throws -> [StoredMessage]
    /// 同じ ID のメールがあれば置き換える。
    func upsert(_ messages: [StoredMessage]) async throws
    func delete(account: AccountID, mailbox: String, uids: Set<UInt32>) async throws
    /// フォルダの保存分と同期の進み具合を消す (`uidValidity` が変わったとき)。
    func deleteAll(account: AccountID, mailbox: String) async throws
    /// アカウントを削除したとき。
    func deleteAccount(_ account: AccountID) async throws
    func allSummaries() async throws -> [MessageSummary]
}

/// テストと SwiftUI プレビュー用。アプリを終了すると消える。
public actor InMemoryMessageStore: MessageStore {
    private struct FolderKey: Hashable {
        let account: AccountID
        let mailbox: String
    }

    private var states: [FolderKey: MailboxSyncState] = [:]
    private var stored: [MessageID: StoredMessage] = [:]

    public init() {}

    public func syncState(account: AccountID, mailbox: String) -> MailboxSyncState? {
        states[FolderKey(account: account, mailbox: mailbox)]
    }

    public func setSyncState(_ state: MailboxSyncState, account: AccountID, mailbox: String) {
        states[FolderKey(account: account, mailbox: mailbox)] = state
    }

    public func messages(account: AccountID, mailbox: String) -> [StoredMessage] {
        stored.values.filter { $0.summary.accountID == account && $0.mailbox == mailbox }
    }

    public func upsert(_ messages: [StoredMessage]) {
        for message in messages { stored[message.summary.id] = message }
    }

    public func delete(account: AccountID, mailbox: String, uids: Set<UInt32>) {
        stored = stored.filter { _, message in
            !(message.summary.accountID == account && message.mailbox == mailbox && uids.contains(message.uid))
        }
    }

    public func deleteAll(account: AccountID, mailbox: String) {
        stored = stored.filter { _, message in !(message.summary.accountID == account && message.mailbox == mailbox) }
        states[FolderKey(account: account, mailbox: mailbox)] = nil
    }

    public func deleteAccount(_ account: AccountID) {
        stored = stored.filter { _, message in message.summary.accountID != account }
        states = states.filter { key, _ in key.account != account }
    }

    public func allSummaries() -> [MessageSummary] {
        stored.values.map(\.summary)
    }
}
