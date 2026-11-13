import MailStore
import SwiftUI

/// メインウィンドウ: 波の背景の上に、サイドバー・メール一覧・本文の 3 枚のガラスのパネルを浮かべる (SPEC 8.3、見本の画像)。
///
/// 標準の `NavigationSplitView` は列にふつうのウィンドウの背景を敷くので、背景の波が隠れてガラスの質感が出ない。
/// そのため、パネルを自分で並べる。
struct MainWindow: View {
    @State private var model: InboxModel

    init(repository: any MailRepository) {
        _model = State(initialValue: InboxModel(repository: repository))
    }

    var body: some View {
        HStack(spacing: Metrics.panelGap) {
            SidebarView(model: model)
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
        .task { await model.load() }
    }
}

#Preview("メインウィンドウ") {
    MainWindow(repository: PreviewMailRepository())
        .frame(width: 1400, height: 820)
}
