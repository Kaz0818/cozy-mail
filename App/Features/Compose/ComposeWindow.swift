import MailStore
import SwiftUI
import UniformTypeIdentifiers

/// 新規作成・返信・全員に返信・転送のウィンドウ (T18、SPEC US-6)。
/// 差出人のアカウント、宛先 (To / Cc / Bcc)、件名、本文、添付ファイル。`⌘↩` で送る。
struct ComposeWindow: View {
    let request: ComposeRequest
    @Environment(MailService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var model: ComposeModel?

    var body: some View {
        Group {
            if let model {
                ComposeForm(model: model, onFinished: finish)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(AppBackground())
        .navigationTitle(model?.windowTitle ?? "新規メッセージ")
        .task {
            let model = ComposeModel(repository: service.repository)
            self.model = model
            await model.load(request)
        }
    }

    /// 送れたら閉じて、送信済みを読み直す。
    private func finish() {
        Task { await service.syncAll() }
        dismiss()
    }
}

private struct ComposeForm: View {
    @Bindable var model: ComposeModel
    let onFinished: () -> Void
    @State private var isImporting = false
    @State private var importError: String?
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case to
        case cc
        case bcc
        case subject
        case body
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            TextEditor(text: $model.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .focused($focus, equals: .body)
                .accessibilityLabel(Text("本文"))
                .accessibilityIdentifier("compose.body")
            if !model.attachments.isEmpty {
                attachmentList
            }
            if let message = model.errorMessage ?? importError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("compose.error")
            }
        }
        .glassPanel()
        .padding(EdgeInsets(top: Metrics.titleBarBand, leading: Metrics.panelGap, bottom: Metrics.panelGap, trailing: Metrics.panelGap))
        .disabled(model.isSending)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addFiles(result)
        }
        .onChange(of: model.isLoading, initial: true) { _, loading in
            guard !loading else { return }
            // 返信は本文の先頭から、新規作成・転送は宛先から書き始める
            focus = model.to.isEmpty ? .to : .body
        }
        .alert(
            "送りました",
            isPresented: .constant(isSentButNotSaved),
            actions: { Button("OK", action: onFinished) },
            message: {
                Text("相手には届いていますが、このアカウントの「送信済み」フォルダに残せませんでした。")
            }
        )
        .onChange(of: model.outcome) { _, outcome in
            if outcome == .sent { onFinished() }
        }
    }

    private var isSentButNotSaved: Bool {
        if case .sentButNotSaved = model.outcome { return true }
        return false
    }

    // MARK: - 見出し (差出人・宛先・件名・ボタン)

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                fieldLabel("差出人")
                Picker("差出人", selection: $model.accountID) {
                    ForEach(model.accounts) { account in
                        Text("\(account.displayName) <\(account.emailAddress)>").tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("compose.from")
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textPrimary)
                .glassCapsule()
                .help(Text("ファイルを添付"))
                .accessibilityLabel(Text("ファイルを添付"))
                Button {
                    Task { await model.send() }
                } label: {
                    Group {
                        if model.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("送信", systemImage: "paperplane.fill")
                        }
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.onAccentFill)
                .glassCapsule(isProminent: true)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
                .help(Text("送信 (⌘↩)"))
                .accessibilityIdentifier("compose.send")
            }
            recipientRow("宛先", text: $model.to, field: .to, identifier: "compose.to")
            if model.showsCcAndBcc {
                recipientRow("Cc", text: $model.cc, field: .cc, identifier: "compose.cc")
                recipientRow("Bcc", text: $model.bcc, field: .bcc, identifier: "compose.bcc")
            } else {
                HStack {
                    Spacer()
                    Button("Cc / Bcc を追加") { model.showsCcAndBcc = true }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(Palette.accent)
                }
            }
            HStack(spacing: 10) {
                fieldLabel("件名")
                TextField("件名", text: $model.subject)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .focused($focus, equals: .subject)
                    .accessibilityIdentifier("compose.subject")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func recipientRow(_ title: String, text: Binding<String>, field: Field, identifier: String) -> some View {
        HStack(spacing: 10) {
            fieldLabel(title)
            TextField(title, text: text, prompt: Text("名前 <you@example.com>, ..."))
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.textPrimary)
                .focused($focus, equals: field)
                .accessibilityIdentifier(identifier)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 48, alignment: .leading)
    }

    // MARK: - 添付ファイル

    private var attachmentList: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        Text(attachment.filename)
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                            .foregroundStyle(Palette.textSecondary)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(attachment.filename) を外す"))
                    }
                    .font(.callout)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCard()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
    }

    private func addFiles(_ result: Result<[URL], any Error>) {
        importError = nil
        switch result {
        case let .success(urls):
            for url in urls {
                let canAccess = url.startAccessingSecurityScopedResource()
                defer { if canAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    model.addAttachment(filename: url.lastPathComponent, mimeType: type, data: data)
                } catch {
                    importError = "「\(url.lastPathComponent)」を読めませんでした。"
                }
            }
        case .failure:
            importError = "ファイルを選べませんでした。"
        }
    }
}
