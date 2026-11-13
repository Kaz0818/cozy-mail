import MailStore
import SwiftUI

/// 右の列: 件名、差出人、宛先、日時、本文、添付ファイル (見本の右の列)。
/// ボタンは T15 / T18 で動くようにする。いまは見た目だけ。
struct ReaderView: View {
    let model: InboxModel

    var body: some View {
        Group {
            if let message = model.selectedMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ReaderHeader(message: message, recipients: model.selectedBody?.to ?? [])
                        Divider()
                        if let body = model.selectedBody {
                            Text(body.text)
                                .font(.body)
                                .lineSpacing(6)
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
                    .padding(28)
                    .frame(maxWidth: 820, alignment: .leading)
                }
            } else {
                ContentUnavailableView("メールを選んでください", systemImage: "envelope.open")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { ReaderToolbar() }
    }
}

private struct ReaderHeader: View {
    let message: MessageSummary
    let recipients: [Contact]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Text(message.subject)
                    .font(.title.weight(.bold))
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
        .glassPanel(cornerRadius: Metrics.rowRadius)
    }
}

/// 本文の上のツールバー。macOS 26 では OS がガラスにしてくれる。
private struct ReaderToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button("返信", systemImage: "arrowshape.turn.up.left") {}
            Button("全員に返信", systemImage: "arrowshape.turn.up.left.2") {}
        }
        ToolbarItemGroup {
            Button("削除", systemImage: "trash") {}
            Button("アーカイブ", systemImage: "archivebox") {}
            Button("フラグ", systemImage: "flag") {}
            Button("その他", systemImage: "ellipsis") {}
        }
    }
}
