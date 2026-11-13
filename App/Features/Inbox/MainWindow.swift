import MailStore
import SwiftUI

/// メインウィンドウ: サイドバー → メール一覧 → 本文 の 3 列 (SPEC 8.3)。
struct MainWindow: View {
    @State private var model: InboxModel
    @State private var searchText = ""

    init(repository: any MailRepository) {
        _model = State(initialValue: InboxModel(repository: repository))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            MessageListView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 480)
        } detail: {
            ReaderView(model: model)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("メールを検索"))
        .background(AppBackground())
        .tint(Palette.accent)
        .frame(minWidth: 900, minHeight: 600)
        .task { await model.load() }
    }
}

#Preview("メインウィンドウ") {
    MainWindow(repository: PreviewMailRepository())
        .frame(width: 1400, height: 820)
}
