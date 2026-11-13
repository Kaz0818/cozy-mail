import MailStore
import SwiftUI

@main
struct CozyMailApp: App {
    static let mainWindowID = "main"
    static let composeWindowID = "compose"

    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue
    /// 画面の自動テスト (`-ui-testing` で起動) では、本物のアカウントやキーチェーンに触れないよう、メモリ上だけで動かす。
    @State private var service = ProcessInfo.processInfo.arguments.contains("-ui-testing") ? MailService.preview() : MailService.live()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
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
            MessageCommands()
            CommandMenu("メールボックス") {
                Button("新着メールを受信") {
                    Task { await service.syncAll() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        // 作成ウィンドウ (新規作成・返信・全員に返信・転送)。開くたびに別のウィンドウになる
        WindowGroup("新規メッセージ", id: Self.composeWindowID, for: ComposeRequest.self) { $request in
            ComposeWindow(request: request ?? .new())
                .environment(service)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 640)

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
