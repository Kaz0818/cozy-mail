/// 画面がメールを取りに行く窓口。
/// 画面はこのプロトコルだけを使い、仮データ (`PreviewMailRepository`) と本物の同期処理を差し替えられるようにする。
public protocol MailRepository: Sendable {
    func accounts() async throws -> [Account]
    /// 新しい順に並べて返す。
    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary]
    func unreadCount(in selection: MailboxSelection) async throws -> Int
    func body(for id: MessageID) async throws -> MessageBody
}

public enum MailRepositoryError: Error, Equatable {
    case messageNotFound(MessageID)
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
