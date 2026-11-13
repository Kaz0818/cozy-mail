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
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("アカウントを追加…") { isAdding = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
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

#Preview("アカウントの設定") {
    AccountsSettings()
        .environment(MailService.preview())
}
