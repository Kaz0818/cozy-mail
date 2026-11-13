import MailStore
import SwiftUI

@main
struct CozyMailApp: App {
    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue
    @State private var service = MailService.live()

    var body: some Scene {
        WindowGroup {
            // アカウントがないうちは見本のメール、追加したら本物のメールを出す
            MainWindow()
                .environment(service)
                .onChange(of: themeRawValue, initial: true) {
                    AppTheme.stored(themeRawValue).apply()
                }
        }
        // タイトルバーを消し、中身をウィンドウ全体に広げる (赤・黄・緑のボタンはサイドバーのパネルの上に乗る)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandMenu("メールボックス") {
                Button("新着メールを受信") {
                    Task { await service.syncAll() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            TabView {
                Tab("アカウント", systemImage: "at") {
                    AccountsSettings()
                }
                Tab("見た目", systemImage: "paintpalette") {
                    AppearanceSettings()
                }
            }
            .environment(service)
        }
    }
}
