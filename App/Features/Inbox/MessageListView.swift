import MailStore
import SwiftUI

/// 真ん中の列: 見出し、新規作成ボタン、絞り込みタブ、メールの行 (見本の真ん中の列)。
struct MessageListView: View {
    let model: InboxModel
    @Environment(MailService.self) private var service
    @Environment(\.openWindow) private var openWindow
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isShowingSamples {
                Notice(
                    systemImage: "sparkles",
                    text: "これは見本のメールです。左上の「＋」からアカウントを追加すると、本物のメールが表示されます。"
                )
            } else if let error = model.actionError {
                Notice(systemImage: "exclamationmark.triangle.fill", text: error, isWarning: true)
            } else if let error = service.syncError {
                Notice(systemImage: "exclamationmark.triangle.fill", text: "受信できなかったアカウントがあります。\n\(error)", isWarning: true)
            }
            FilterTabs(selection: model.filter) { filter in
                Task { await model.setFilter(filter) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.messages) { message in
                            MessageRow(
                                message: message,
                                accountName: model.accountName(for: message),
                                isSelected: model.selectedMessageID == message.id,
                                menu: menu(for: message)
                            ) {
                                isListFocused = true
                                Task { await model.selectMessage(message.id) }
                            }
                        }
                    }
                }
                // キーボードで選んだメールが見えるように、一覧を動かす
                .onChange(of: model.selectedMessageID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            // 一覧にカーソルがあるときだけ、1 文字のショートカット (↑ ↓ J K E S ⌫) を受ける
            .focusable()
            .focused($isListFocused)
            .focusEffectDisabled()
            .modifier(MessageListKeys(model: model))
            .onAppear { isListFocused = true }
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView("メールはありません", systemImage: "tray")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
    }

    /// 行の右クリックのメニュー。項目の中身と押せるかどうかは `InboxModel.menuEntries(for:)` が決める。
    private func menu(for message: MessageSummary) -> [ContextMenuEntry] {
        model.menuEntries(for: message).map { entry -> ContextMenuEntry in
            switch entry {
            case let .action(title, action, isEnabled):
                return .item(title, isEnabled: isEnabled) {
                    Task { await model.perform(action, on: message.id) }
                }
            case .separator:
                return .separator
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text(model.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button {
                Task { await service.syncAll() }
            } label: {
                Group {
                    if service.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .font(.title3)
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary)
            .glassCapsule()
            .disabled(service.isSyncing || service.isShowingSamples)
            .accessibilityLabel(Text("新着メールを受信"))
            .help(Text("新着メールを受信 (⇧⌘N)"))
            Button {
                openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.new())
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.onAccentFill)
            .glassCapsule(isProminent: true)
            .accessibilityLabel(Text("新規作成"))
            .accessibilityIdentifier("compose.new")
            .help(Text("新規作成 (⌘N)"))
        }
        .padding(.horizontal, 6)
    }
}

/// 一覧の上に出す短いお知らせ。
private struct Notice: View {
    let systemImage: String
    let text: String
    var isWarning = false

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(isWarning ? Palette.destructive : Palette.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .padding(.horizontal, 6)
    }
}

/// 「すべて / 未読 / スター付き」のタブ。
struct FilterTabs: View {
    let selection: MessageFilter
    let onSelect: (MessageFilter) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MessageFilter.allCases, id: \.self) { filter in
                let isSelected = filter == selection
                Button {
                    onSelect(filter)
                } label: {
                    Text(title(filter))
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Palette.onAccentFill : Palette.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassCapsule(isProminent: isSelected)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
    }

    private func title(_ filter: MessageFilter) -> LocalizedStringKey {
        switch filter {
        case .all: "すべて"
        case .unread: "未読"
        case .starred: "スター付き"
        }
    }
}

/// メール 1 通の行。未読は点と太字の両方で示す (色だけに頼らない)。
/// クリックで選び、右クリックで `menu` のメニューを出す (`rightClickMenu` を参照)。
struct MessageRow: View {
    let message: MessageSummary
    let accountName: String
    let isSelected: Bool
    let menu: [ContextMenuEntry]
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isRead ? Color.clear : Palette.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 16)
            AvatarView(name: message.sender.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender.name)
                        .font(.body.weight(message.isRead ? .medium : .bold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(MailDateText.list(message.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(secondaryText)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(message.subject)
                        .font(.callout.weight(message.isRead ? .regular : .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .foregroundStyle(message.isStarred ? Color.yellow : secondaryText)
                        .accessibilityLabel(Text(message.isStarred ? "スター付き" : "スターなし"))
                }
                Text(message.preview)
                    .font(.callout)
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .selectionGlass(isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .rightClickMenu(menu)
        // 読み上げ (VoiceOver) では、これまでどおりボタンとして扱う
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(accountName))
        .accessibilityAction(.default, action)
        // 読み上げでは、右クリックのメニューと同じ操作を「アクション」から選べる
        .accessibilityActions {
            ForEach(Array(menu.enumerated()), id: \.offset) { _, entry in
                if case let .item(title, isEnabled, perform) = entry, isEnabled {
                    Button(title) { perform() }
                }
            }
        }
        .accessibilityIdentifier("messageRow.\(message.id.rawValue)")
    }

    private var primaryText: Color {
        isSelected ? Palette.onAccentFill : Palette.textPrimary
    }

    private var secondaryText: Color {
        isSelected ? Palette.onAccentFill.opacity(0.8) : Palette.textSecondary
    }
}
