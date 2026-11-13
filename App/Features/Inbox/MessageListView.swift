import MailStore
import SwiftUI

/// 真ん中の列: 見出し、新規作成ボタン、絞り込みタブ、メールの行 (見本の真ん中の列)。
struct MessageListView: View {
    let model: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
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
