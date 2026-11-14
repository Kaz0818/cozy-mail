import SwiftUI

/// 設定の「通知」(T20b)。
struct NotificationSettings: View {
    @AppStorage(NotificationService.enabledKey) private var notifiesNewMail = true

    var body: some View {
        Form {
            Toggle("新着メールを通知する", isOn: $notifiesNewMail)
            Text("受信トレイに新しい未読メールが届いたら、Mac の通知で知らせます。4 通以上まとめて届いたときは 1 つにまとめます。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
