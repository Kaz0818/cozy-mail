import MailStore
import SwiftUI

@main
struct CozyMailApp: App {
    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            // T11 で本物のメールに差し替えるまでは、見本と同じ仮データを出す
            MainWindow(repository: PreviewMailRepository())
                .onChange(of: themeRawValue, initial: true) {
                    AppTheme.stored(themeRawValue).apply()
                }
        }
        // タイトルバーを消し、中身をウィンドウ全体に広げる (赤・黄・緑のボタンはサイドバーのパネルの上に乗る)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1400, height: 860)

        Settings {
            TabView {
                Tab("見た目", systemImage: "paintpalette") {
                    AppearanceSettings()
                }
            }
        }
    }
}
