import AppKit
import MailStore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 右の列: 件名、差出人、宛先、日時、本文、添付ファイル (見本の右の列)。
/// 返信・転送のボタンは作成ウィンドウを開く (T18)。
struct ReaderView: View {
    let model: InboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ReaderToolbar(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            if let message = model.selectedMessage {
                MessageContent(model: model, message: message)
                    // メールを変えたら「画像を表示」などの状態を初めに戻す
                    .id(message.id)
            } else {
                ContentUnavailableView("メールを選んでください", systemImage: "envelope.open")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 1 通のメールの中身。HTML メールは安全な WebView で、テキストのメールはそのまま表示する。
private struct MessageContent: View {
    let model: InboxModel
    let message: MessageSummary
    @State private var allowsRemoteContent = false
    @State private var previewURL: URL?
    @State private var attachmentError: String?
    /// 保存する添付ファイル。入れると保存先を選ぶ画面が開く。
    @State private var exportFile: AttachmentFile?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReaderHeader(
                message: message,
                recipients: model.selectedBody?.to ?? [],
                canToggleStar: model.canPerform(message.isStarred ? .unstar : .star, on: message),
                onToggleStar: { Task { await model.perform(message.isStarred ? .unstar : .star, on: message.id) } }
            )
                .padding(.horizontal, 32)
                .padding(.top, 12)
            Divider()
                .padding(.horizontal, 32)
            content
        }
        .padding(.bottom, 20)
        .quickLookPreview($previewURL)
        // 保存先を選ぶ画面。サンドボックスのアプリ向けの SwiftUI の仕組みを使う
        .fileExporter(
            isPresented: $isExporting,
            document: exportFile,
            contentType: exportFile?.contentType ?? .data,
            defaultFilename: exportFile?.filename
        ) { result in
            if case let .failure(error) = result {
                attachmentError = "添付ファイルを保存できませんでした。(\(error.localizedDescription))"
            }
            exportFile = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let body = model.selectedBody {
            if let html = body.html {
                if !allowsRemoteContent, SafeHTML.hasRemoteContent(html) {
                    remoteContentBanner
                }
                HTMLMessageView(html: html, allowsRemoteContent: allowsRemoteContent)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 24)
                if !body.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) { attachmentCards(body) }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                    }
                    .scrollIndicators(.never)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(body.text)
                            .font(.body)
                            .lineSpacing(7)
                            .foregroundStyle(Palette.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        attachmentCards(body)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.destructive)
                    .padding(.horizontal, 32)
            }
        } else if let error = model.bodyError {
            VStack(spacing: 14) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.destructive)
                    .multilineTextAlignment(.center)
                Button("もう一度試す") { Task { await model.retryBody() } }
                    .buttonStyle(.glass)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("本文を取得しています…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 外部の画像を読み込んでいないことを知らせ、表示するかどうかを選んでもらう。
    private var remoteContentBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(Palette.textSecondary)
            Text("外部の画像は表示していません (読んだことを送り主に知られないため)。")
                .font(.callout)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("画像を表示") { allowsRemoteContent = true }
                .buttonStyle(.glass)
        }
        .padding(12)
        .glassCard()
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func attachmentCards(_ body: MessageBody) -> some View {
        ForEach(body.attachments, id: \.index) { attachment in
            AttachmentCard(
                attachment: attachment,
                onPreview: { Task { await preview(attachment) } },
                onSave: { Task { await save(attachment) } }
            )
        }
    }

    /// 一時フォルダに書き出して、Quick Look で見せる。
    private func preview(_ attachment: Attachment) async {
        attachmentError = nil
        do {
            let data = try await model.attachmentData(attachment)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(SafeHTML.safeFileName(attachment.filename))
            try data.write(to: url)
            previewURL = url
        } catch {
            attachmentError = "添付ファイルを開けませんでした。(\(error.localizedDescription))"
        }
    }

    /// 中身を取ってから、保存先を選ぶ画面を開く。
    private func save(_ attachment: Attachment) async {
        attachmentError = nil
        do {
            let data = try await model.attachmentData(attachment)
            exportFile = AttachmentFile(attachment: attachment, data: data)
            isExporting = true
        } catch {
            attachmentError = "添付ファイルを保存できませんでした。(\(error.localizedDescription))"
        }
    }
}

/// 保存する添付ファイル (SwiftUI の `fileExporter` に渡す形)。
struct AttachmentFile: FileDocument {
    /// どんな種類のファイルでも保存できるよう、すべての種類の元になる `.item` にする。
    static var readableContentTypes: [UTType] { [.item] }

    let data: Data
    let filename: String
    let contentType: UTType

    init(attachment: Attachment, data: Data) {
        self.data = data
        filename = SafeHTML.safeFileName(attachment.filename)
        // 知らない拡張子や MIME タイプからは「仮の種類」(dynamic) が作られることがあるので、それは使わない
        let pathExtension = (filename as NSString).pathExtension
        let byExtension = pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension).flatMap { $0.isDynamic ? nil : $0 }
        let byMIMEType = UTType(mimeType: attachment.mimeType).flatMap { $0.isDynamic ? nil : $0 }
        contentType = byExtension ?? byMIMEType ?? .data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = configuration.file.filename ?? "attachment"
        contentType = .data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ReaderHeader: View {
    let message: MessageSummary
    let recipients: [Contact]
    let canToggleStar: Bool
    let onToggleStar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Text(message.subject)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Button(action: onToggleStar) {
                    Image(systemName: message.isStarred ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(message.isStarred ? Color.yellow : Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canToggleStar)
                .help(Text(message.isStarred ? "スターを外す" : "スターを付ける"))
                .accessibilityLabel(Text(message.isStarred ? "スターを外す" : "スターを付ける"))
            }
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: message.sender.name.isEmpty ? message.sender.address : message.sender.name, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(message.sender.name.isEmpty ? message.sender.address : message.sender.name)
                            .font(.headline)
                            .foregroundStyle(Palette.textPrimary)
                        if !message.sender.name.isEmpty {
                            Text("<\(message.sender.address)>")
                                .foregroundStyle(Palette.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !recipients.isEmpty {
                        HStack(spacing: 4) {
                            Text("To:").foregroundStyle(Palette.textSecondary)
                            Text(recipients.map { $0.name.isEmpty ? $0.address : $0.name }.joined(separator: ", "))
                                .foregroundStyle(Palette.textPrimary)
                                .lineLimit(1)
                        }
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
    let onPreview: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: attachment.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 12)
            Button(action: onPreview) {
                Image(systemName: "eye")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassCapsule()
            .help(Text("プレビュー"))
            .accessibilityLabel(Text("\(attachment.filename) をプレビュー"))
            Button(action: onSave) {
                Image(systemName: "arrow.down.to.line")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .glassCapsule()
            .help(Text("保存"))
            .accessibilityLabel(Text("\(attachment.filename) を保存"))
        }
        .padding(16)
        .frame(minWidth: 320, maxWidth: 520)
        .glassCard()
        .onTapGesture(count: 2, perform: onPreview)
    }
}

/// 本文パネルの上に並ぶボタンと検索欄 (見本の右上)。返信と全員に返信は 1 つのカプセルにまとめる。
/// ボタンは T15 / T18 で動くようにする。いまは見た目だけ。
private struct ReaderToolbar: View {
    let model: InboxModel
    /// 打っている途中の言葉は、ここに持つ (日本語の変換中に、画面の外の値で上書きされないように)
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.openWindow) private var openWindow

    private func compose(_ kind: ComposeRequest.Kind) {
        guard let id = model.selectedMessageID else { return }
        openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.replying(kind, to: id))
    }

    var body: some View {
        let message = model.selectedMessage
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ToolbarIcon(title: "返信", systemImage: "arrowshape.turn.up.left", isEnabled: message != nil) {
                    compose(.reply)
                }
                ToolbarIcon(title: "全員に返信", systemImage: "arrowshape.turn.up.left.2", isEnabled: message != nil) {
                    compose(.replyAll)
                }
                ToolbarIcon(title: "転送", systemImage: "arrowshape.turn.up.right", isEnabled: message != nil) {
                    compose(.forward)
                }
            }
            .glassCapsule()
            ToolbarIcon(title: "削除", systemImage: "trash", isEnabled: model.canPerform(.moveToTrash, on: message)) {
                Task { await model.perform(.moveToTrash) }
            }
            .glassCapsule()
            ToolbarIcon(title: "アーカイブ", systemImage: "archivebox", isEnabled: model.canPerform(.archive, on: message)) {
                Task { await model.perform(.archive) }
            }
            .glassCapsule()
            ToolbarIcon(
                title: message?.isStarred == true ? "スターを外す" : "スターを付ける",
                systemImage: message?.isStarred == true ? "star.fill" : "star",
                isEnabled: model.canPerform(message?.isStarred == true ? .unstar : .star, on: message)
            ) {
                Task { await model.perform(message?.isStarred == true ? .unstar : .star) }
            }
            .glassCapsule()
            Menu {
                Button("未読にする") { Task { await model.perform(.markUnread) } }
                    .disabled(!model.canPerform(.markUnread, on: message))
                Button("既読にする") { Task { await model.perform(.markRead) } }
                    .disabled(!model.canPerform(.markRead, on: message))
                Divider()
                Button("迷惑メールにする") { Task { await model.perform(.markAsJunk) } }
                    .disabled(!model.canPerform(.markAsJunk, on: message))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .frame(width: 44, height: 38)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassCapsule()
            .help(Text("その他"))
            .disabled(model.isShowingSamples || message == nil)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textSecondary)
                // 打つたびに、Mac に保存したメールから探す (T19)
                TextField("メールを検索", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.textPrimary)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("search.field")
                    // ⌘F (メニューの「メールを検索」) でここにカーソルを置く
                    .onChange(of: model.searchFocusRequest) { isSearchFocused = true }
                    // esc で検索をやめる
                    .onExitCommand { searchText = "" }
                    .onChange(of: searchText) { Task { await model.search(searchText) } }
                    // フォルダを選んで検索が終わったら、欄も空にする
                    .onChange(of: model.searchText) { if model.searchText != searchText { searchText = model.searchText } }
                if model.isSearching {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("検索をやめる"))
                    .accessibilityLabel(Text("検索をやめる"))
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 260, height: 38)
            .glassCapsule()
        }
    }
}

private struct ToolbarIcon: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: 44, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
