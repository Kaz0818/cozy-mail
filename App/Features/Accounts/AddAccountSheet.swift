import MailStore
import SwiftUI

/// アカウント追加のシート (US-1、US-2)。メールアドレスとアプリパスワードを入れると、サーバー設定は自動で入る。
struct AddAccountSheet: View {
    @Environment(MailService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var choice: ProviderChoice = .automatic
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("アカウントを追加")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.textPrimary)

            Form {
                TextField("メールアドレス", text: $email, prompt: Text("you@gmail.com"))
                    .textContentType(.username)
                SecureField("アプリパスワード", text: $password)
                    .textContentType(.password)
                TextField("表示名", text: $displayName, prompt: Text("例: Gmail (仕事)"))
                Picker("メールの種類", selection: $choice) {
                    Text("自動で判定").tag(ProviderChoice.automatic)
                    Text("Gmail (Google Workspace を含む)").tag(ProviderChoice.gmail)
                    Text("Yahoo!メール (Yahoo! JAPAN)").tag(ProviderChoice.yahooJapan)
                    Text("Yahoo! Mail (海外)").tag(ProviderChoice.yahoo)
                    Text("iCloud メール").tag(ProviderChoice.icloud)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            Text("ふだんのパスワードではなく、メールの事業者の設定画面で発行した「アプリパスワード」を入れてください。パスワードはこの Mac のキーチェーンにだけ保存します。")
                .font(.callout)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking {
                    ProgressView().controlSize(.small)
                    Text("ログインを確かめています…")
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("追加") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func submit() async {
        isWorking = true
        errorMessage = nil
        do {
            try await service.addAccount(email: email, password: password, displayName: displayName, choice: choice)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
        isWorking = false
    }
}

#Preview("アカウントを追加") {
    AddAccountSheet()
        .environment(MailService.preview())
}
