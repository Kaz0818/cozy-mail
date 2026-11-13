import Foundation

/// 本物のメール (同期して保存したもの) を画面に渡す窓口。仮データの `PreviewMailRepository` と差し替えて使う。
public struct LiveMailRepository: MailRepository {
    public typealias MessageFetcher = @Sendable (StoredMessage) async throws -> Data

    private let store: any MessageStore
    private let accountList: @Sendable () async throws -> [Account]
    private let fetchMessage: MessageFetcher?

    /// - Parameters:
    ///   - accounts: いま登録されているアカウント。削除されたアカウントのメールは出さない。
    ///   - fetchMessage: まだ保存していない本文をサーバーから取る。nil なら取らない。
    public init(
        store: any MessageStore,
        accounts: @escaping @Sendable () async throws -> [Account],
        fetchMessage: MessageFetcher? = nil
    ) {
        self.store = store
        accountList = accounts
        self.fetchMessage = fetchMessage
    }

    public func accounts() async throws -> [Account] {
        try await accountList()
    }

    public func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        try await visibleSummaries()
            .filter { selection.contains($0) && filter.matches($0) }
            .sorted { $0.date > $1.date }
    }

    /// 受信トレイ (と、それを絞り込んだ「未読」) は、サーバーから聞いた数があればそれを使う。
    /// まだ聞けていないアカウントと、ほかのフォルダは、保存しているメールを数える。
    public func unreadCount(in selection: MailboxSelection) async throws -> Int {
        let summaries = try await visibleSummaries()
        let localCount = { (account: AccountID?) in
            summaries.count { message in
                (account == nil || message.accountID == account) && selection.contains(message) && !message.isRead
            }
        }
        guard selection.role == .inbox || selection.role == .unread else { return localCount(selection.accountID) }

        let accounts = try await accountList().filter { selection.accountID == nil || $0.id == selection.accountID }
        var total = 0
        for account in accounts {
            if let fromServer = try await store.inboxUnreadCount(account: account.id) {
                total += fromServer
            } else {
                total += localCount(account.id)
            }
        }
        return total
    }

    /// 本文。初めて開いたときはサーバーから取って保存し、一覧の書き出しも埋める。2 回目からは保存分を使う。
    public func body(for id: MessageID) async throws -> MessageBody {
        let raw = try await rawMessage(for: id)
        return try MessageBodyBuilder.body(id: id, raw: raw)
    }

    public func attachmentData(for id: MessageID, index: Int) async throws -> Data {
        try MessageBodyBuilder.attachmentData(raw: try await rawMessage(for: id), index: index)
    }

    private func rawMessage(for id: MessageID) async throws -> Data {
        let ids = Set(try await accountList().map(\.id))
        guard let stored = try await store.message(id: id), ids.contains(stored.summary.accountID) else {
            throw MailRepositoryError.messageNotFound(id)
        }
        if let saved = try await store.rawMessage(for: id) { return saved }
        guard let fetchMessage else { throw MailRepositoryError.bodyUnavailable }

        let raw = try await fetchMessage(stored)
        try await store.setRawMessage(raw, for: id)
        if let body = try? MessageBodyBuilder.body(id: id, raw: raw) {
            var updated = stored
            updated.summary.preview = MessageBodyBuilder.preview(of: body)
            try await store.upsert([updated])
        }
        return raw
    }

    /// 登録中のアカウントのメールだけ。
    private func visibleSummaries() async throws -> [MessageSummary] {
        let ids = Set(try await accountList().map(\.id))
        return try await store.allSummaries().filter { ids.contains($0.accountID) }
    }
}
