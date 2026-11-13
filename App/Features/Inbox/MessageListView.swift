import MailStore
import SwiftUI

/// 真ん中の列: 見出し、新規作成ボタン、絞り込みタブ、メールの行 (見本の真ん中の列)。
struct MessageListView: View {
    let model: InboxModel
    @Environment(MailService.self) private var service

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
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.messages) { message in
                        MessageRow(
                            message: message,
                            accountName: model.accountName(for: message),
                            isSelected: model.selectedMessageID == message.id
                        ) {
                            Task { await model.selectMessage(message.id) }
                        }
                        .contextMenu { MessageActionsMenu(model: model, message: message) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .overlay {
                if model.messages.isEmpty {
                    ContentUnavailableView("メールはありません", systemImage: "tray")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
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
                // T18 で作成ウィンドウを開く
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.onAccentFill)
            .glassCapsule(isProminent: true)
            .accessibilityLabel(Text("新規作成"))
            .help(Text("新規作成 (⌘N)"))
        }
        .padding(.horizontal, 6)
    }
}

/// 行を右クリックしたときのメニュー。
private struct MessageActionsMenu: View {
    let model: InboxModel
    let message: MessageSummary

    var body: some View {
        if message.isRead {
            Button("未読にする") { Task { await model.perform(.markUnread, on: message.id) } }
                .disabled(!model.canPerform(.markUnread, on: message))
        } else {
            Button("既読にする") { Task { await model.perform(.markRead, on: message.id) } }
                .disabled(!model.canPerform(.markRead, on: message))
        }
        Button(message.isStarred ? "スターを外す" : "スターを付ける") {
            Task { await model.perform(message.isStarred ? .unstar : .star, on: message.id) }
        }
        .disabled(!model.canPerform(message.isStarred ? .unstar : .star, on: message))
        Divider()
        Button("アーカイブ") { Task { await model.perform(.archive, on: message.id) } }
            .disabled(!model.canPerform(.archive, on: message))
        Button("削除") { Task { await model.perform(.moveToTrash, on: message.id) } }
            .disabled(!model.canPerform(.moveToTrash, on: message))
        Button("迷惑メールにする") { Task { await model.perform(.markAsJunk, on: message.id) } }
            .disabled(!model.canPerform(.markAsJunk, on: message))
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
struct MessageRow: View {
    let message: MessageSummary
    let accountName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(accountName))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var primaryText: Color {
        isSelected ? Palette.onAccentFill : Palette.textPrimary
    }

    private var secondaryText: Color {
        isSelected ? Palette.onAccentFill.opacity(0.8) : Palette.textSecondary
    }
}
