import AppKit
import MailStore
import UserNotifications

/// Mac の通知センターに新着の通知を出し、押されたらそのメールを開いてもらう (T20b、US-12)。
/// 何を通知するかは `NewMailNotifier` (MailStore) が決める。ここは出すだけ。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    /// 設定の「新着メールを通知する」(初めは入)。
    static let enabledKey = "notifications.newMail"
    private nonisolated static let messageIDKey = "messageID"

    /// 通知が押されたとき。開くメール (まとめた通知では nil) を渡す。
    var onOpen: ((MessageID?) -> Void)?
    private var started = false

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// 通知を受け取れるようにし、初めてなら Mac に許可を求める。
    func start() {
        guard !started else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ alerts: [NewMailAlert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.subtitle = alert.subtitle
            content.body = alert.body
            content.sound = .default
            // 通知センターで、アカウントごとにまとめて並べる
            content.threadIdentifier = alert.accountName
            if let id = alert.messageID { content.userInfo = [Self.messageIDKey: id.rawValue] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// アプリが前にあっても、通知を出す (別のウィンドウや別のメールを見ていることがあるため)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let rawID = response.notification.request.content.userInfo[Self.messageIDKey] as? String
        await MainActor.run {
            NSApplication.shared.activate()
            self.onOpen?(rawID.map(MessageID.init))
        }
    }
}
