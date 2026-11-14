import Foundation

/// メニューバーに出す中身 (T21、US-12): 未読数 (Dock と同じ) と、最近の未読メール。
/// 画面から切り離してあるので、Linux でもテストできる。
public struct MenuBarSummary: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var id: MessageID
        public var sender: String
        public var subject: String
    }

    /// メニューに並べる未読メールの数。
    public static let recentLimit = 5

    /// 未読数の文字。0・見本のときは nil。
    public var countLabel: String?
    /// 新しい順の未読メール (最大 5 通)。見本のときは空。
    public var recent: [Item]

    public init(unreadCount: Int, unreadMessages: [MessageSummary], isShowingSamples: Bool) {
        countLabel = DockBadge.label(unreadCount: unreadCount, isShowingSamples: isShowingSamples)
        recent = isShowingSamples ? [] : unreadMessages
            .filter { !$0.isRead }
            .sorted { $0.date > $1.date }
            .prefix(Self.recentLimit)
            .map { message in
                let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                return Item(id: message.id, sender: message.sender.displayName, subject: subject.isEmpty ? "(件名なし)" : subject)
            }
    }

    public static let empty = MenuBarSummary(unreadCount: 0, unreadMessages: [], isShowingSamples: true)
}
