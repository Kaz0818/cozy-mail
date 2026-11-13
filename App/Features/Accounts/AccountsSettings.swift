import MailStore
import SwiftUI

/// 設定ウィンドウ (`⌘,`) の「アカウント」タブ。追加と削除。
struct AccountsSettings: View {
    @Environment(MailService.self) private var service
    @State private var isAdding = false
    @State private var pendingRemoval: Account?

    var body: some View {
        Form {
            Section {
                if service.accounts.isEmpty {
                    Text("アカウントはまだありません。")
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(service.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProviderIcon(provider: account.provider)
                            VStack(alignment: .leading) {
                                Text(account.displayName)
                                Text(account.emailAddress)
                                    .font(.callout)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer()
                            Button("削除…", role: .destructive) { pendingRemoval = account }
                        }
                        SenderNameField(account: account)
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("アカウントを追加…") { isAdding = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .sheet(isPresented: $isAdding) { AddAccountSheet() }
        .confirmationDialog(
            "\(pendingRemoval?.displayName ?? "") を削除しますか?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("削除", role: .destructive) {
                Task { await service.removeAccount(account.id) }
            }
        } message: { _ in
            Text("この Mac に保存したパスワードとメールも消えます。サーバー上のメールは消えません。")
        }
    }
}

/// 差出人の名前 (送ったメールで相手に見える名前)。Return を押すか、欄から離れたときに保存する。
private struct SenderNameField: View {
    let account: Account
    @Environment(MailService.self) private var service
    @State private var name = ""
    @State private var message: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("差出人の名前", text: $name, prompt: Text("例: 山田 太郎 (空ならアドレスだけ)"))
                .focused($isFocused)
                .onSubmit(save)
                .onChange(of: isFocused) { _, focused in
                    if !focused { save() }
                }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .onAppear { name = account.senderName }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed != account.senderName else { return }
        Task {
            do {
                try await service.setSenderName(trimmed, for: account.id)
                message = trimmed.isEmpty ? "メールアドレスだけで送ります。" : "「\(trimmed)」として送ります。"
            } catch let error as AccountError {
                message = error.userMessage
            } catch {
                message = "保存できませんでした: \(error)"
            }
        }
    }
}

#Preview("アカウントの設定") {
    AccountsSettings()
        .environment(MailService.preview())
}
