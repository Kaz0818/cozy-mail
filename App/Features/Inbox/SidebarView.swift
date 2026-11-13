import MailStore
import SwiftUI

/// 左の列: アプリ名、アカウント一覧、統合受信トレイ、フォルダ一覧 (見本の左の列)。
struct SidebarView: View {
    let model: InboxModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                appHeader
                accountsSection
                foldersSection
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.open.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Palette.brand.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text("Mail")
                .font(.title2.weight(.bold))
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Cozy Mail"))
    }

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            SectionHeader(title: "アカウント", systemImage: "plus", actionLabel: "アカウントを追加") {
                // T11 / T12 でアカウント追加の画面を開く
            }
            ForEach(model.accounts) { item in
                SidebarRow(
                    title: item.account.displayName,
                    icon: AnyView(ProviderIcon(provider: item.account.provider)),
                    badge: item.unreadCount,
                    isSelected: model.selection == .account(item.id, .inbox)
                ) {
                    Task { await model.select(.account(item.id, .inbox)) }
                }
            }
            SidebarRow(
                title: "統合受信トレイ",
                icon: AnyView(Image(systemName: "tray.2")),
                badge: model.unifiedUnreadCount,
                isSelected: model.selection == .unified(.inbox),
                isProminent: true
            ) {
                Task { await model.select(.unified(.inbox)) }
            }
            .padding(.top, 6)
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            SectionHeader(title: "フォルダ", systemImage: "ellipsis", actionLabel: "フォルダの操作") {}
            ForEach(model.folders) { folder in
                let selection = folderSelection(folder.role)
                SidebarRow(
                    title: InboxModel.folderName(folder.role),
                    icon: AnyView(Image(systemName: InboxModel.folderSymbol(folder.role))),
                    badge: folder.badge,
                    isSelected: model.selection == selection
                ) {
                    Task { await model.select(selection) }
                }
            }
        }
    }

    /// アカウントを選んでいる間は、そのアカウントのフォルダを開く。
    private func folderSelection(_ role: MailboxRole) -> MailboxSelection {
        if let accountID = model.selection.accountID { return .account(accountID, role) }
        return .unified(role)
    }
}

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String
    let actionLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textPrimary)
            .glassCapsule()
            .accessibilityLabel(Text(actionLabel))
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }
}

/// サイドバーの 1 行。選ばれているとティファニーブルーのガラスになる。
private struct SidebarRow: View {
    let title: String
    let icon: AnyView
    let badge: Int
    let isSelected: Bool
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 22)
                    .foregroundStyle(isSelected ? Palette.onAccentFill : Palette.textSecondary)
                Text(title)
                    .foregroundStyle(isSelected ? Palette.onAccentFill : Palette.textPrimary)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
                CountBadge(count: badge, isProminent: isSelected)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isProminent ? 9 : 7)
            .contentShape(Rectangle())
            .selectionGlass(isSelected: isSelected, cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// アカウントの種類を表す小さなアイコン。各社のロゴは使わず、色付きの封筒で区別する。
struct ProviderIcon: View {
    let provider: MailProvider

    var body: some View {
        Image(systemName: "envelope.fill")
            .foregroundStyle(color)
            .accessibilityLabel(Text(name))
    }

    private var color: Color {
        switch provider {
        case .gmail: .red
        case .yahoo: .purple
        case .icloud: .blue
        case .outlook: .indigo
        case .other: Palette.accent
        }
    }

    private var name: String {
        switch provider {
        case .gmail: "Gmail"
        case .yahoo: "Yahoo!"
        case .icloud: "iCloud"
        case .outlook: "Outlook"
        case .other: "メール"
        }
    }
}
