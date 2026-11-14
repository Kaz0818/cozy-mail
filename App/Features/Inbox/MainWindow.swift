import AppKit
import MailStore
import SwiftUI

/// メインウィンドウ: 波の背景の上に、サイドバー・メール一覧・本文の 3 枚のガラスのパネルを浮かべる (SPEC 8.3、見本の画像)。
///
/// 標準の `NavigationSplitView` は列にふつうのウィンドウの背景を敷くので、背景の波が隠れてガラスの質感が出ない。
/// そのため、パネルを自分で並べる。
struct MainWindow: View {
    @Environment(MailService.self) private var service
    @State private var model = InboxModel(repository: PreviewMailRepository(), isShowingSamples: true)
    @State private var isAddingAccount = false

    var body: some View {
        HStack(spacing: Metrics.panelGap) {
            SidebarView(model: model, onAddAccount: { isAddingAccount = true })
                .frame(width: 250)
                .frame(maxHeight: .infinity, alignment: .top)
                .glassPanel()
            MessageListView(model: model)
                .frame(width: 370)
                .frame(maxHeight: .infinity, alignment: .top)
                .glassPanel()
            ReaderView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .glassPanel()
        }
        // 上はウィンドウの赤・黄・緑のボタンのための帯。パネルの角と重ならないよう、パネルはその下から始める
        .padding(EdgeInsets(top: Metrics.titleBarBand, leading: Metrics.panelGap, bottom: Metrics.panelGap, trailing: Metrics.panelGap))
        .background(AppBackground())
        .tint(Palette.accent)
        .frame(minWidth: 1000, minHeight: 620)
        .ignoresSafeArea()
        .sheet(isPresented: $isAddingAccount) { AddAccountSheet() }
        // メニューバーの「メッセージ」メニューが、このウィンドウのメールに対して動くように
        .focusedSceneValue(\.inboxModel, model)
        .task { await service.start() }
        // アカウントの追加・削除や同期のたびに、画面のデータを読み直す
        .task(id: service.revision) {
            await model.use(service.repository, showingSamples: service.isShowingSamples)
        }
        // Dock のアイコンの未読数 (T30)。数が変わるたびに付け替える。nil なら外す
        .onChange(of: model.dockBadgeLabel, initial: true) { _, label in
            NSApplication.shared.dockTile.badgeLabel = label
        }
    }
}

#Preview("メインウィンドウ") {
    MainWindow()
        .environment(MailService.preview())
        .frame(width: 1400, height: 820)
}
