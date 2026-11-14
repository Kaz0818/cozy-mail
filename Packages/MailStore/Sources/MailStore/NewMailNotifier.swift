import Foundation

/// 新着の通知 1 つ分の中身 (T20b)。出すのはアプリ (UserNotifications) の役目。
public struct NewMailAlert: Sendable, Hashable {
    public var title: String
    public var subtitle: String
    public var body: String
    /// 押したときに開くメール。まとめた通知では nil (統合受信トレイを開く)。
    public var messageID: MessageID?
    public var accountName: String

    public init(title: String, subtitle: String, body: String, messageID: MessageID?, accountName: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.messageID = messageID
        self.accountName = accountName
    }
}

/// 新しく来たメールから、出す通知を決める (T20b、US-12)。画面から切り離してあるので、Linux でもテストできる。
public enum NewMailNotifier {
    /// これ以上の数が一度に来たら、1 つの通知にまとめる。
    public static let summaryThreshold = 4

    /// 受信トレイの未読だけを、新しい順に通知にする。`summaryThreshold` 通以上なら 1 つにまとめる。
    public static func alerts(for messages: [MessageSummary], accounts: [Account]) -> [NewMailAlert] {
        let names = Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let targets = messages
            .filter { $0.mailbox == .inbox && !$0.isRead }
            .sorted { $0.date > $1.date }
        guard let newest = targets.first else { return [] }
        if targets.count >= summaryThreshold {
            let senders = targets.prefix(3).map(\.sender.displayName).joined(separator: "、")
            let accountNames = Set(targets.map(\.accountID)).compactMap { names[$0] }.sorted()
            return [NewMailAlert(
                title: "\(targets.count) 件の新着メール",
                subtitle: accountNames.count == 1 ? accountNames[0] : "すべてのアカウント",
                body: "\(senders) ほか",
                messageID: nil,
                accountName: names[newest.accountID] ?? ""
            )]
        }
        return targets.map { message in
            let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            return NewMailAlert(
                title: message.sender.displayName,
                subtitle: subject.isEmpty ? "(件名なし)" : subject,
                body: message.preview,
                messageID: message.id,
                accountName: names[message.accountID] ?? ""
            )
        }
    }
}
