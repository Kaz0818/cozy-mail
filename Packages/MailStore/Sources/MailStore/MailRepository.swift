import Foundation

/// 画面がメールを取りに行く窓口。
/// 画面はこのプロトコルだけを使い、仮データ (`PreviewMailRepository`) と本物の同期処理を差し替えられるようにする。
public protocol MailRepository: Sendable {
    func accounts() async throws -> [Account]
    /// 新しい順に並べて返す。
    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary]
    func unreadCount(in selection: MailboxSelection) async throws -> Int
    /// Mac に保存したメールから探す (T19)。迷惑メールとゴミ箱を除く、すべてのアカウントとフォルダ。新しい順。
    /// 空白で区切った言葉は、すべてを含むもの。差出人の名前・アドレス・件名・本文の書き出しから探す。
    func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary]
    /// サーバーで探す (T27)。Mac に保存していない古いメールや、本文の言葉でも見つかる。新しい順。
    /// 保存していないメールは `ServerMessage` の番号で返す (開けるが、整理の操作はできない)。
    func searchServer(_ text: String) async throws -> [MessageSummary]
    /// そのアカウントの Gmail のラベル (自分で作ったもの)。名前順。
    func labels(for account: AccountID) async throws -> [String]
    /// 本文。必要ならサーバーから取る。
    func body(for id: MessageID) async throws -> MessageBody
    /// 添付ファイルの中身 (`Attachment.index` で指定)。
    func attachmentData(for id: MessageID, index: Int) async throws -> Data
    /// 既読・スター・アーカイブ・削除・迷惑メール。画面にはすぐ反映し、サーバーが断ったら元に戻して投げる。
    func perform(_ action: MessageAction, on id: MessageID) async throws
    /// まとめて操作する (T26)。できないメールは飛ばす。失敗があれば、ほかを済ませてから最初の失敗を投げる。
    func perform(_ action: MessageAction, on ids: [MessageID]) async throws
    /// 返信・転送のための、元のメールの情報 (T18)。
    func replySource(for id: MessageID) async throws -> ReplySource
    /// メールを送る (T18)。送ったあと、Gmail 以外は「送信済み」フォルダにも入れる。
    func send(_ draft: Draft) async throws -> SendOutcome
    /// 受信トレイをすべて既読にする。Mac に保存していない古い未読も、サーバーで既読にする。
    /// `account` が nil なら、すべてのアカウント。返すのは、サーバーで既読にした数。
    func markInboxRead(account: AccountID?) async throws -> Int
}

/// 送信の結果。
public enum SendOutcome: Sendable, Equatable {
    case sent
    /// 送れたが、「送信済み」フォルダに残せなかった (理由)。
    case sentButNotSaved(String)
}

extension MailRepository {
    /// ラベルを扱わない窓口 (見本のメール、テスト用のものなど) の既定: ラベルはない。
    public func labels(for account: AccountID) async throws -> [String] {
        []
    }

    /// 検索に対応していない窓口 (テスト用のものなど) の既定: 見つからない。
    public func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary] {
        []
    }

    /// サーバー側の検索に対応していない窓口 (見本のメール、テスト用のものなど) の既定: 見つからない。
    public func searchServer(_ text: String) async throws -> [MessageSummary] {
        []
    }

    /// 送信に対応していない窓口 (テスト用のものなど) の既定: できない。
    public func replySource(for id: MessageID) async throws -> ReplySource {
        throw MailRepositoryError.actionUnavailable
    }

    public func send(_ draft: Draft) async throws -> SendOutcome {
        throw MailRepositoryError.actionUnavailable
    }

    /// サーバーにつながない窓口 (見本のメール、テスト用のものなど) の既定: できない。
    public func markInboxRead(account: AccountID?) async throws -> Int {
        throw MailRepositoryError.actionUnavailable
    }

    /// まとめての操作の既定: 1 通ずつ行う。1 通だけならその結果をそのまま返し、複数ならできないメールは飛ばす。
    public func perform(_ action: MessageAction, on ids: [MessageID]) async throws {
        if ids.count == 1, let id = ids.first { return try await perform(action, on: id) }
        var firstError: (any Error)?
        for id in ids {
            do {
                try await perform(action, on: id)
            } catch MailRepositoryError.actionNotApplicable {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

/// メールに対する整理の操作 (T15)。
public enum MessageAction: String, Sendable, Hashable, Codable {
    case markRead
    case markUnread
    case star
    case unstar
    /// 受信トレイから外す (Gmail は「受信トレイ」ラベルを外す、それ以外はアーカイブのフォルダへ移す)。
    case archive
    case moveToTrash
    case markAsJunk
}

public enum MailRepositoryError: Error, Equatable {
    case messageNotFound(MessageID)
    /// 本文を取る方法がない (サーバーにつながっていない)。
    case bodyUnavailable
    case attachmentNotFound
    /// 見本のメールなど、操作できないもの。
    case actionUnavailable
    /// このメールにはできない操作 (受信トレイにないメールのアーカイブ、ゴミ箱のメールをゴミ箱へ、など)。
    case actionNotApplicable
    /// 移す先のフォルダがサーバーにない。
    case noFolder(MailboxRole)
}

extension MailboxSelection {
    /// このフォルダにメールが含まれるかどうか。仮想フォルダの条件もここで決める。
    /// - Parameter labels: そのメールの Gmail のラベル (`StoredMessage.labels`)。ラベルを選んでいるときだけ使う。
    func contains(_ message: MessageSummary, labels: [String] = []) -> Bool {
        if let accountID, message.accountID != accountID { return false }
        switch self {
        case let .label(_, name):
            // Gmail の Web 版と同じく、迷惑メールとゴミ箱のメールはラベルの一覧に出さない
            return labels.contains(name) && message.mailbox != .trash && message.mailbox != .junk
        case .unified(.starred), .account(_, .starred):
            return message.isStarred && message.mailbox != .trash && message.mailbox != .junk
        case .unified(.unread), .account(_, .unread):
            return !message.isRead && message.mailbox == .inbox
        case let .unified(role), let .account(_, role):
            return message.mailbox == role
        }
    }
}

extension MessageFilter {
    func matches(_ message: MessageSummary) -> Bool {
        switch self {
        case .all: true
        case .unread: !message.isRead
        case .starred: message.isStarred
        }
    }
}
