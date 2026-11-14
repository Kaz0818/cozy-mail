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

/// 一覧と未読数のための絞り込み。保存先が自分の中で (SwiftData ならデータベースで) 絞り込めるよう、条件だけを渡す。
/// 何年分のメールがあっても、画面を更新するたびに全部を読み込まずに済む。
public struct MessageQuery: Sendable, Hashable {
    /// このアカウントのメールだけ (登録中のもの。削除したアカウントのメールは出さない)。
    public var accounts: Set<AccountID>
    public var selection: MailboxSelection
    public var filter: MessageFilter

    public init(accounts: Set<AccountID>, selection: MailboxSelection, filter: MessageFilter = .all) {
        self.accounts = accounts
        self.selection = selection
        self.filter = filter
    }

    /// 画面の決まり (`MailboxSelection.contains`・`MessageFilter.matches`) どおりかどうか。保存先の実装はこれと同じ結果を返す。
    public func matches(_ message: StoredMessage) -> Bool {
        let summary = message.summary
        return accounts.contains(summary.accountID)
            && selection.contains(summary, labels: message.labels)
            && filter.matches(summary)
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
    /// サーバーから聞いた受信トレイの未読数。まだ聞けていなければ nil。
    func inboxUnreadCount(account: AccountID) async throws -> Int?
    func setInboxUnreadCount(_ count: Int, account: AccountID) async throws
    /// 保存しているすべてのメール。何年分もあると重いので、画面には使わない (`summaries(matching:)` を使う)。
    func allSummaries() async throws -> [MessageSummary]
    /// 条件に合うメールを、新しい順に。
    func summaries(matching query: MessageQuery) async throws -> [MessageSummary]
    /// 条件に合うメールのうち、未読の数。
    func unreadCount(matching query: MessageQuery) async throws -> Int
    func message(id: MessageID) async throws -> StoredMessage?
    /// 取得したメール全体の生データ (本文と添付)。まだ取っていなければ nil。
    func rawMessage(for id: MessageID) async throws -> Data?
    func setRawMessage(_ data: Data, for id: MessageID) async throws
    /// 役割 (ゴミ箱など) ごとのサーバー上のフォルダ名。同期のたびに覚え直す。
    func mailboxName(for role: MailboxRole, account: AccountID) async throws -> String?
    func setMailboxNames(_ names: [MailboxRole: String], account: AccountID) async throws
    /// Gmail の自分で作ったラベルの一覧 (サイドバーに出す)。同期のたびに覚え直す。まだなければ空。
    func labels(account: AccountID) async throws -> [String]
    func setLabels(_ labels: [String], account: AccountID) async throws
}

/// テストと SwiftUI プレビュー用。アプリを終了すると消える。
public actor InMemoryMessageStore: MessageStore {
    private struct FolderKey: Hashable {
        let account: AccountID
        let mailbox: String
    }

    private var states: [FolderKey: MailboxSyncState] = [:]
    private var stored: [MessageID: StoredMessage] = [:]
    private var inboxUnread: [AccountID: Int] = [:]
    private var raw: [MessageID: Data] = [:]
    private var mailboxNames: [AccountID: [MailboxRole: String]] = [:]
    private var labelLists: [AccountID: [String]] = [:]

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
        removeMessages { $0.summary.accountID == account && $0.mailbox == mailbox && uids.contains($0.uid) }
    }

    public func deleteAll(account: AccountID, mailbox: String) {
        removeMessages { $0.summary.accountID == account && $0.mailbox == mailbox }
        states[FolderKey(account: account, mailbox: mailbox)] = nil
    }

    public func deleteAccount(_ account: AccountID) {
        removeMessages { $0.summary.accountID == account }
        states = states.filter { key, _ in key.account != account }
        inboxUnread[account] = nil
        mailboxNames[account] = nil
        labelLists[account] = nil
    }

    public func mailboxName(for role: MailboxRole, account: AccountID) -> String? {
        mailboxNames[account]?[role]
    }

    public func setMailboxNames(_ names: [MailboxRole: String], account: AccountID) {
        mailboxNames[account] = names
    }

    public func labels(account: AccountID) -> [String] {
        labelLists[account] ?? []
    }

    public func setLabels(_ labels: [String], account: AccountID) {
        labelLists[account] = labels
    }

    public func inboxUnreadCount(account: AccountID) -> Int? {
        inboxUnread[account]
    }

    public func setInboxUnreadCount(_ count: Int, account: AccountID) {
        inboxUnread[account] = count
    }

    public func allSummaries() -> [MessageSummary] {
        stored.values.map(\.summary)
    }

    public func summaries(matching query: MessageQuery) -> [MessageSummary] {
        stored.values.filter(query.matches).map(\.summary).sorted { $0.date > $1.date }
    }

    public func unreadCount(matching query: MessageQuery) -> Int {
        stored.values.count { query.matches($0) && !$0.summary.isRead }
    }

    public func message(id: MessageID) -> StoredMessage? {
        stored[id]
    }

    public func rawMessage(for id: MessageID) -> Data? {
        raw[id]
    }

    public func setRawMessage(_ data: Data, for id: MessageID) {
        raw[id] = data
    }

    /// メールと、その生データをまとめて消す。
    private func removeMessages(where shouldRemove: (StoredMessage) -> Bool) {
        for (id, message) in stored where shouldRemove(message) {
            stored[id] = nil
            raw[id] = nil
        }
    }
}
