import MailStore
import SwiftUI

@main
struct CozyMailApp: App {
    static let mainWindowID = "main"
    static let composeWindowID = "compose"

    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue
    /// アプリを終える前に、送るのを待っているメールを送る (T24)。`MailService` はここが持つ。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var service: MailService { appDelegate.service }
    /// メニューバーの中身と Dock の未読数 (T21、T30)。
    @State private var menuBar = MenuBarModel()

    /// 自動テストで起動されたかどうか。
    /// - 画面のテスト: `-ui-testing` を付けて起動する。
    /// - 単体テスト: このアプリを起動して、その中でテストが動く。そのとき XCTest が `XCTestConfigurationFilePath` を設定する。
    static func isAutomatedTest(_ process: ProcessInfo) -> Bool {
        isAutomatedTest(arguments: process.arguments, environment: process.environment)
    }

    static func isAutomatedTest(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-ui-testing") || environment["XCTestConfigurationFilePath"] != nil
    }

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

        // メニューバーに常駐する (T21)。ウィンドウを閉じても、アプリは終わらずに新着を受け取る
        MenuBarExtra {
            MenuBarContent(model: menuBar, service: service)
        } label: {
            MenuBarLabel(model: menuBar, service: service)
        }

        Settings {
            TabView {
                Tab("一般", systemImage: "gearshape") {
                    GeneralSettings()
                }
                Tab("アカウント", systemImage: "at") {
                    AccountsSettings()
                }
                Tab("見た目", systemImage: "paintpalette") {
                    AppearanceSettings()
                }
                Tab("通知", systemImage: "bell") {
                    NotificationSettings()
                }
            }
            .environment(service)
        }
    }
}

/// アプリ全体の出来事を受け取る。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 自動テストでは、本物のアカウント・キーチェーン・保存ファイルに触れないよう、メモリ上だけで動かす。
    let service = CozyMailApp.isAutomatedTest(ProcessInfo.processInfo) ? MailService.preview() : MailService.live()

    /// 送信の取り消しを待っているメールがあれば、待たずに送り終えてから終わる (T24)。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard service.hasPendingSends else { return .terminateNow }
        let service = service
        Task {
            // 送れなかったら終えない (書いたものを失わないよう、メインウィンドウで知らせて開き直せるようにする)
            let allSent = await service.flushSends()
            sender.reply(toApplicationShouldTerminate: allSent)
        }
        return .terminateLater
    }
}
