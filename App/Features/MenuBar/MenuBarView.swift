import AppKit
import MailStore
import SwiftUI

/// メニューバーのアイコン: 封筒と未読数 (T21)。
/// アプリが動いている間ずっとあるので、通知から開くメールのためのウィンドウもここから開く。
struct MenuBarLabel: View {
    let model: MenuBarModel
    let service: MailService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: model.summary.countLabel == nil ? "envelope" : "envelope.badge")
            if let count = model.summary.countLabel {
                Text(count)
            }
        }
        // 受信・既読などで中身が変わるたびに、未読数と最近のメールを読み直す
        .task(id: service.revision) {
            await model.refresh(repository: service.repository, isShowingSamples: service.isShowingSamples)
        }
        // Dock のアイコンの未読数 (T30)。数が変わるたびに付け替える。nil なら外す
        .onChange(of: model.dockBadgeLabel, initial: true) { _, label in
            NSApplication.shared.dockTile.badgeLabel = label
        }
        // 通知が押されたとき、メインウィンドウが閉じていたら開く (開いたウィンドウがそのメールを出す)
        .onChange(of: service.openRequest) {
            if service.mainWindowCount == 0 { openWindow(id: CozyMailApp.mainWindowID) }
        }
    }
}

/// メニューバーのメニュー (T21): 最近の未読メール、受信、開く、設定、終了。
struct MenuBarContent: View {
    let model: MenuBarModel
    let service: MailService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.summary.recent.isEmpty {
            Text("未読のメールはありません")
        } else {
            Section("未読のメール") {
                ForEach(model.summary.recent) { item in
                    Button("\(item.sender) — \(item.subject)") { open(item.id) }
                }
            }
        }
        Divider()
        Button("新着メールを受信") {
            Task { await service.syncAll() }
        }
        .disabled(service.isSyncing)
        Button("Cozy Mail を開く") { showMainWindow() }
        SettingsLink { Text("設定…") }
        Divider()
        Button("Cozy Mail を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// そのメールを統合受信トレイで開く。
    private func open(_ id: MessageID) {
        service.requestOpen(id)
        showMainWindow()
    }

    /// メインウィンドウを前に出す。閉じていたら開く。
    private func showMainWindow() {
        NSApplication.shared.activate()
        if service.mainWindowCount == 0 {
            openWindow(id: CozyMailApp.mainWindowID)
        } else if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix(CozyMailApp.mainWindowID) == true
        }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
