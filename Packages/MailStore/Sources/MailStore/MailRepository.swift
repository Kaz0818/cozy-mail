import Foundation

/// 画面がメールを取りに行く窓口。
/// 画面はこのプロトコルだけを使い、仮データ (`PreviewMailRepository`) と本物の同期処理を差し替えられるようにする。
public protocol MailRepository: Sendable {
    func accounts() async throws -> [Account]
    /// 新しい順に並べて返す。
    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary]
    func unreadCount(in selection: MailboxSelection) async throws -> Int
    /// 本文。必要ならサーバーから取る。
    func body(for id: MessageID) async throws -> MessageBody
    /// 添付ファイルの中身 (`Attachment.index` で指定)。
    func attachmentData(for id: MessageID, index: Int) async throws -> Data
    /// 既読・スター・アーカイブ・削除・迷惑メール。画面にはすぐ反映し、サーバーが断ったら元に戻して投げる。
    func perform(_ action: MessageAction, on id: MessageID) async throws
}

/// メールに対する整理の操作 (T15)。
public enum MessageAction: Sendable, Hashable {
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
    func contains(_ message: MessageSummary) -> Bool {
        if let accountID, message.accountID != accountID { return false }
        switch role {
        case .starred:
            return message.isStarred && message.mailbox != .trash && message.mailbox != .junk
        case .unread:
            return !message.isRead && message.mailbox == .inbox
        default:
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
