import Foundation

/// 本物のメール (同期して保存したもの) を画面に渡す窓口。仮データの `PreviewMailRepository` と差し替えて使う。
public struct LiveMailRepository: MailRepository {
    private let store: any MessageStore
    private let accountList: @Sendable () async throws -> [Account]

    /// - Parameter accounts: いま登録されているアカウント。削除されたアカウントのメールは出さない。
    public init(store: any MessageStore, accounts: @escaping @Sendable () async throws -> [Account]) {
        self.store = store
        accountList = accounts
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

    /// 本文の取得は T14 で作る。それまでは、一覧の情報から仮の本文を返す。
    public func body(for id: MessageID) async throws -> MessageBody {
        guard let summary = try await visibleSummaries().first(where: { $0.id == id }) else {
            throw MailRepositoryError.messageNotFound(id)
        }
        let text = summary.preview.isEmpty ? "(本文の表示は、次の段階で対応します)" : summary.preview
        return MessageBody(messageID: id, to: [], text: text)
    }

    /// 登録中のアカウントのメールだけ。
    private func visibleSummaries() async throws -> [MessageSummary] {
        let ids = Set(try await accountList().map(\.id))
        return try await store.allSummaries().filter { ids.contains($0.accountID) }
    }
}
