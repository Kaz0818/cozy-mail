import Foundation
import MailCore

/// サーバーにまだ送れていない整理の操作 1 つ (T22、US-13)。
/// 同じアカウント・同じフォルダのメールへの操作を、サーバーに送る形 (フォルダ名と UID) のまま持つ。
public struct PendingAction: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var accountID: AccountID
    public var action: MessageAction
    /// 操作したときにメールがあったサーバーのフォルダ。
    public var mailbox: String
    public var uids: [UInt32]
    /// 移す先のフォルダ (移す操作のときだけ。Gmail のアーカイブはラベルを外すだけなので nil)。
    public var destination: String?
    /// Gmail か (アーカイブのやり方が違う)。
    public var gmail: Bool
    public var queuedAt: Date

    public init(
        id: UUID = UUID(), accountID: AccountID, action: MessageAction, mailbox: String, uids: [UInt32],
        destination: String?, gmail: Bool, queuedAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.action = action
        self.mailbox = mailbox
        self.uids = uids
        self.destination = destination
        self.gmail = gmail
        self.queuedAt = queuedAt
    }

    /// サーバーに送る。
    func send(on session: any MailServerSession) async throws {
        switch action {
        case .markRead, .markUnread:
            try await session.setFlags(["\\Seen"], add: action == .markRead, in: mailbox, uids: uids)
        case .star, .unstar:
            try await session.setFlags(["\\Flagged"], add: action == .star, in: mailbox, uids: uids)
        case .archive where gmail:
            try await session.setGmailLabels(["\\Inbox"], add: false, in: mailbox, uids: uids)
        case .archive, .moveToTrash, .markAsJunk:
            guard let destination else { throw MailRepositoryError.actionNotApplicable }
            try await session.move(uids: uids, from: mailbox, to: destination)
        }
    }

    /// つながらない (オフライン、途中で切れた) ための失敗か。そうなら、操作はためておいてあとで送る。
    /// サーバーが断った・ログインできないなどは、送り直しても同じなので、ためない。
    public static func isOffline(_ error: any Error) -> Bool {
        switch error as? IMAPError {
        case .connectionFailed, .connectionClosed: true
        default: false
        }
    }
}

/// オフラインの待ち行列 (T22、US-13)。つながらないときの整理の操作をためて、つながったら古い順に送る。
/// アプリを終えても残るよう、1 つの JSON ファイルに保存する。SwiftData のモデル (保存データの形) は変えない。
public actor PendingActionQueue {
    public let fileURL: URL
    private var actions: [PendingAction]
    /// いま送っているアカウント (同じ操作を 2 回送らないため)。
    private var flushing: Set<AccountID> = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        actions = Self.read(fileURL)
    }

    /// 送る結果。
    public struct FlushResult: Sendable, Equatable {
        /// サーバーに送れた数。
        public var sent: Int
        /// サーバーに断られて、あきらめた数 (Mac の表示は、次の同期でサーバーに合う)。
        public var dropped: Int
        /// ほかで送っている最中だったので、何もしなかった。
        public var busy: Bool

        public init(sent: Int = 0, dropped: Int = 0, busy: Bool = false) {
            self.sent = sent
            self.dropped = dropped
            self.busy = busy
        }
    }

    /// まだ送れていない操作。古い順。`account` が nil ならすべて。
    public func pending(account: AccountID? = nil) -> [PendingAction] {
        actions.filter { account == nil || $0.accountID == account }
    }

    public func hasPending(account: AccountID) -> Bool {
        actions.contains { $0.accountID == account }
    }

    public func append(_ action: PendingAction) throws {
        actions.append(action)
        try write()
    }

    /// そのアカウントの操作を、古い順にサーバーに送る。送れたものから消す。
    /// - つながらなくなったら、そこで止めて投げる (残りはためたまま)。
    /// - サーバーに断られたものは、あきらめて消し、次へ進む。
    public func flush(account: AccountID, session: any MailServerSession) async throws -> FlushResult {
        guard !flushing.contains(account) else { return FlushResult(busy: true) }
        flushing.insert(account)
        defer { flushing.remove(account) }

        var result = FlushResult()
        // 送っている間に足された操作も送る (毎回、ファイルの中身ではなく今の一覧から次を取る)
        while let next = actions.first(where: { $0.accountID == account }) {
            do {
                try await next.send(on: session)
                result.sent += 1
            } catch let error where PendingAction.isOffline(error) {
                throw error
            } catch {
                result.dropped += 1
            }
            actions.removeAll { $0.id == next.id }
            try write()
        }
        return result
    }

    /// 消したアカウントの操作を捨てる。
    public func removeAll(account: AccountID) throws {
        actions.removeAll { $0.accountID == account }
        try write()
    }

    // MARK: - ファイル

    private func write() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 書いている途中で落ちても、前の中身が壊れないように
        try JSONEncoder().encode(actions).write(to: fileURL, options: .atomic)
    }

    /// 読めない (ない、壊れている) ときは空から始める。
    private static func read(_ url: URL) -> [PendingAction] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingAction].self, from: data)) ?? []
    }
}
