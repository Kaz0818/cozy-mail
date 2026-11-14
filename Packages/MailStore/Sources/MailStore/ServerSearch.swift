import Foundation
import MailCore

/// サーバー側の検索で見つけた、Mac に保存していないメールの番号 (T27)。
/// 保存しているメールと区別するため、同期の番号の前に `server/` を付ける。
public enum ServerMessage {
    private static let prefix = "server/"

    public static func messageID(_ syncID: MessageID) -> MessageID {
        MessageID(prefix + syncID.rawValue)
    }

    /// サーバーで見つけた、Mac に保存していないメールか。
    public static func isServerOnly(_ id: MessageID) -> Bool {
        id.rawValue.hasPrefix(prefix)
    }
}

/// サーバー側の検索で見つけたメール (見出しと、開いたときの本文) を、アプリを開いている間だけ覚えておく (T27)。
/// 保存先には入れない (入れると、次の同期でフラグを取り直す範囲が何年分にも広がり、毎回重くなるため)。
/// 新しく探すたびに、前の結果は忘れる。
public actor ServerSearchCache {
    private var messages: [MessageID: StoredMessage] = [:]
    private var raws: [MessageID: Data] = [:]

    public init() {}

    public func message(_ id: MessageID) -> StoredMessage? {
        messages[id]
    }

    func replace(with found: [StoredMessage]) {
        messages = Dictionary(found.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first })
        raws = [:]
    }

    func raw(_ id: MessageID) -> Data? {
        raws[id]
    }

    func setRaw(_ data: Data, for id: MessageID) {
        guard messages[id] != nil else { return }
        raws[id] = data
    }
}

/// サーバー側の検索を足す窓口 (T27、US-10)。ほかはもとの窓口にそのまま頼む。
///
/// - 探すのは、同期しているフォルダ (Gmail は「すべてのメール」) のうち、迷惑メールとゴミ箱を除いたもの (Mac 内の検索と同じ)。
/// - 1 つのフォルダから取るのは、新しい方から `limitPerFolder` 通まで。
/// - Mac に保存しているメールは、保存している形 (ふつうの番号) で返す。保存していないものは `server/` の番号で返し、
///   開く・返信・転送はできるが、整理の操作 (既読・アーカイブなど) はできない。
public struct ServerSearchRepository: MailRepository {
    public typealias SessionOpener = @Sendable (AccountID) async throws -> any MailServerSession

    private let base: any MailRepository
    private let store: any MessageStore
    private let accountList: @Sendable () async throws -> [Account]
    private let openSession: SessionOpener
    private let cache: ServerSearchCache
    private let limitPerFolder: Int

    public init(
        base: any MailRepository,
        store: any MessageStore,
        accounts: @escaping @Sendable () async throws -> [Account],
        openSession: @escaping SessionOpener,
        cache: ServerSearchCache,
        limitPerFolder: Int = 50
    ) {
        self.base = base
        self.store = store
        accountList = accounts
        self.openSession = openSession
        self.cache = cache
        self.limitPerFolder = limitPerFolder
    }

    // MARK: - サーバーで探す

    public func searchServer(_ text: String) async throws -> [MessageSummary] {
        guard !text.allSatisfy(\.isWhitespace) else { return [] }
        let accounts = try await accountList()
        var summaries: [MessageSummary] = []
        var remembered: [StoredMessage] = []
        var firstError: (any Error)?
        var succeeded = false
        for account in accounts {
            do {
                let (found, serverOnly) = try await search(text, account: account)
                summaries += found
                remembered += serverOnly
                succeeded = true
            } catch {
                // つながらないアカウントがあっても、ほかのアカウントは続ける
                if firstError == nil { firstError = error }
            }
        }
        if !succeeded, let firstError { throw firstError }
        await cache.replace(with: remembered)
        return summaries.sorted { $0.date > $1.date }
    }

    private func search(_ text: String, account: Account) async throws -> ([MessageSummary], [StoredMessage]) {
        let session = try await openSession(account.id)
        do {
            let result = try await search(text, account: account, session: session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    private func search(
        _ text: String, account: Account, session: any MailServerSession
    ) async throws -> ([MessageSummary], [StoredMessage]) {
        let gmail = account.provider == .gmail
        let targets = SyncEngine.targets(for: account.provider, mailboxes: try await session.listMailboxes())
            .filter { $0.role != .junk && $0.role != .trash }
        var summaries: [MessageSummary] = []
        var serverOnly: [StoredMessage] = []
        for target in targets {
            let status = try await session.examine(target.name)
            let uids = try await session.searchUIDs(in: target.name, text: text).sorted().suffix(limitPerFolder)
            var missing: [UInt32] = []
            for uid in uids {
                let syncID = MessageID("\(account.id.rawValue)|\(target.name)|\(status.uidValidity)|\(uid)")
                if let stored = try await store.message(id: syncID) {
                    summaries.append(stored.summary)
                } else {
                    missing.append(uid)
                }
            }
            guard !missing.isEmpty else { continue }
            let headers = try await session.fetchHeaders(in: target.name, uids: missing, includeGmailAttributes: gmail)
            for header in headers {
                var message = SyncEngine.makeMessage(
                    header, account: account.id, target: target, uidValidity: status.uidValidity, gmail: gmail
                )
                let old = message.summary
                message.summary = MessageSummary(
                    id: ServerMessage.messageID(old.id), accountID: old.accountID, mailbox: old.mailbox,
                    sender: old.sender, recipients: old.recipients, subject: old.subject, preview: old.preview,
                    date: old.date, isRead: old.isRead, isStarred: old.isStarred, isFlagged: old.isFlagged,
                    hasAttachments: old.hasAttachments
                )
                serverOnly.append(message)
                summaries.append(message.summary)
            }
        }
        return (summaries, serverOnly)
    }

    /// サーバーで見つけたメールの全体 (1 回取ったら覚えておく)。忘れたあとなら `messageNotFound`。
    private func serverRaw(for id: MessageID) async throws -> (Data, StoredMessage) {
        guard let stored = await cache.message(id) else { throw MailRepositoryError.messageNotFound(id) }
        if let raw = await cache.raw(id) { return (raw, stored) }
        let session = try await openSession(stored.summary.accountID)
        let raw: Data
        do {
            raw = try await session.fetchMessage(in: stored.mailbox, uid: stored.uid)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        await cache.setRaw(raw, for: id)
        return (raw, stored)
    }

    // MARK: - サーバーで見つけたメールを開く

    public func body(for id: MessageID) async throws -> MessageBody {
        guard ServerMessage.isServerOnly(id) else { return try await base.body(for: id) }
        let (raw, _) = try await serverRaw(for: id)
        return try MessageBodyBuilder.body(id: id, raw: raw)
    }

    public func attachmentData(for id: MessageID, index: Int) async throws -> Data {
        guard ServerMessage.isServerOnly(id) else { return try await base.attachmentData(for: id, index: index) }
        let (raw, _) = try await serverRaw(for: id)
        return try MessageBodyBuilder.attachmentData(raw: raw, index: index)
    }

    public func replySource(for id: MessageID) async throws -> ReplySource {
        guard ServerMessage.isServerOnly(id) else { return try await base.replySource(for: id) }
        let (raw, stored) = try await serverRaw(for: id)
        return try LiveMailRepository.replySource(raw: raw, id: id, stored: stored)
    }

    /// サーバーで見つけた (保存していない) メールには、整理の操作はできない。
    public func perform(_ action: MessageAction, on id: MessageID) async throws {
        guard !ServerMessage.isServerOnly(id) else { throw MailRepositoryError.actionNotApplicable }
        try await base.perform(action, on: id)
    }

    public func perform(_ action: MessageAction, on ids: [MessageID]) async throws {
        let saved = ids.filter { !ServerMessage.isServerOnly($0) }
        if saved.count < ids.count, saved.isEmpty || ids.count == 1 { throw MailRepositoryError.actionNotApplicable }
        try await base.perform(action, on: saved)
    }

    // MARK: - そのまま頼む

    public func accounts() async throws -> [Account] { try await base.accounts() }

    public func markInboxRead(account: AccountID?) async throws -> Int {
        try await base.markInboxRead(account: account)
    }

    public func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        try await base.messages(in: selection, filter: filter)
    }

    public func unreadCount(in selection: MailboxSelection) async throws -> Int {
        try await base.unreadCount(in: selection)
    }

    public func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary] {
        try await base.search(text, filter: filter)
    }

    public func labels(for account: AccountID) async throws -> [String] {
        try await base.labels(for: account)
    }

    public func send(_ draft: Draft) async throws -> SendOutcome {
        try await base.send(draft)
    }
}
