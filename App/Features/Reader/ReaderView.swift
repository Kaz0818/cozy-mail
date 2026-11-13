import MailStore
import SwiftUI

/// 右の列: 件名、差出人、宛先、日時、本文、添付ファイル (見本の右の列)。
/// ボタンは T15 / T18 で動くようにする。いまは見た目だけ。
struct ReaderView: View {
    let model: InboxModel
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReaderToolbar(searchText: $searchText)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if let message = model.selectedMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ReaderHeader(message: message, recipients: model.selectedBody?.to ?? [])
                        Divider()
                        if let body = model.selectedBody {
                            Text(body.text)
                                .font(.body)
                                .lineSpacing(7)
                                .foregroundStyle(Palette.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(body.attachments, id: \.filename) { attachment in
                                AttachmentCard(attachment: attachment)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            } else {
                ContentUnavailableView("メールを選んでください", systemImage: "envelope.open")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ReaderHeader: View {
    let message: MessageSummary
    let recipients: [Contact]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Text(message.subject)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Image(systemName: message.isStarred ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(message.isStarred ? Color.yellow : Palette.textSecondary)
                    .accessibilityLabel(Text(message.isStarred ? "スター付き" : "スターなし"))
            }
            Divider()
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: message.sender.name, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(message.sender.name)
                            .font(.headline)
                            .foregroundStyle(Palette.textPrimary)
                        Text("<\(message.sender.address)>")
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 4) {
                        Text("To:").foregroundStyle(Palette.textSecondary)
                        Text(recipients.map(\.name).joined(separator: ", "))
                            .foregroundStyle(Palette.textPrimary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                Text(MailDateText.reader(message.date))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

private struct AttachmentCard: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Button {
                // T14 で保存できるようにする
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassCapsule()
            .accessibilityLabel(Text("\(attachment.filename) を保存"))
        }
        .padding(16)
        .frame(maxWidth: 520)
        .glassCard()
    }
}

/// 本文パネルの上に並ぶボタンと検索欄 (見本の右上)。返信と全員に返信は 1 つのカプセルにまとめる。
/// ボタンは T15 / T18 で動くようにする。いまは見た目だけ。
private struct ReaderToolbar: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ToolbarIcon(title: "返信", systemImage: "arrowshape.turn.up.left")
                ToolbarIcon(title: "全員に返信", systemImage: "arrowshape.turn.up.left.2")
            }
            .glassCapsule()
            ToolbarIcon(title: "削除", systemImage: "trash").glassCapsule()
            ToolbarIcon(title: "アーカイブ", systemImage: "archivebox").glassCapsule()
            ToolbarIcon(title: "フラグ", systemImage: "flag").glassCapsule()
            ToolbarIcon(title: "その他", systemImage: "ellipsis").glassCapsule()
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textSecondary)
                TextField("メールを検索", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(width: 260, height: 38)
            .glassCapsule()
        }
    }
}

private struct ToolbarIcon: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Button {} label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
