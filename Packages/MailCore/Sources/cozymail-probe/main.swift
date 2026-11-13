import AccountKit
import Foundation
import MailCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 実際のメールサーバーにつないで、フォルダ一覧と受信トレイの最新 20 通の件名を表示する確認用のツール。
///
/// アプリパスワードで (Gmail も Yahoo! も。準備は docs/app-passwords.md):
///   swift run --package-path Packages/MailCore cozymail-probe <IMAP サーバー> <メールアドレス> [ポート]
///   パスワードは環境変数 COZYMAIL_PASSWORD があればそれを使い、なければ入力を求める。
///
/// Google ログインで (Gmail。P2 で保留中。準備は docs/google-oauth-setup.md):
///   COZYMAIL_GOOGLE_CLIENT_ID=... COZYMAIL_GOOGLE_CLIENT_SECRET=... \
///   swift run --package-path Packages/MailCore cozymail-probe --gmail [メールアドレス]
///   ブラウザが開くので、ログインするアカウントを選ぶ。
///
/// パスワードやトークンは画面にも記録にも出さない。

let usage = """
使い方:
  cozymail-probe <IMAP サーバー> <メールアドレス> [ポート]
  cozymail-probe --gmail [メールアドレス]
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func readPassword() -> String {
    if let fromEnvironment = environment["COZYMAIL_PASSWORD"], !fromEnvironment.isEmpty {
        return fromEnvironment
    }
    guard let entered = getpass("アプリパスワード: ") else { return "" }
    return String(cString: entered)
}

func openInBrowser(_ url: URL) {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    try? process.run()
    #endif
}

/// ブラウザで Google にログインして、メールアドレスとアクセストークンを得る。
func signInWithGoogle(loginHint: String?) async throws -> IMAPCredentials {
    guard let clientID = environment["COZYMAIL_GOOGLE_CLIENT_ID"], !clientID.isEmpty else {
        print("環境変数 COZYMAIL_GOOGLE_CLIENT_ID を設定してください (docs/google-oauth-setup.md)。")
        exit(64)
    }
    let client = OAuthClient(configuration: .google(
        clientID: clientID, clientSecret: environment["COZYMAIL_GOOGLE_CLIENT_SECRET"]
    ))
    let receiver = try await LoopbackRedirectReceiver.start()
    let pkce = PKCE()
    let state = UUID().uuidString
    let url = client.authorizationURL(redirectURI: receiver.redirectURI, state: state, pkce: pkce, loginHint: loginHint)
    print("ブラウザで Google にログインしてください。開かない場合は、次の URL を開いてください:\n\(url.absoluteString)\n")
    openInBrowser(url)

    let redirect = try await receiver.waitForRedirect()
    let code = try OAuthClient.authorizationCode(from: redirect, expectedState: state)
    let tokens = try await client.exchange(code: code, pkce: pkce, redirectURI: receiver.redirectURI)
    guard let email = tokens.email ?? loginHint else {
        print("メールアドレスを読み取れませんでした。")
        exit(1)
    }
    print("\(email) としてログインしました (更新用トークン: \(tokens.refreshToken == nil ? "なし" : "あり"))。")
    return .oauth2(username: email, accessToken: tokens.accessToken)
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd HH:mm"

do {
    let server: IMAPServer
    let credentials: IMAPCredentials
    if arguments.first == "--gmail" {
        credentials = try await signInWithGoogle(loginHint: arguments.dropFirst().first)
        server = IMAPServer(host: "imap.gmail.com")
    } else if arguments.count >= 2 {
        let port = arguments.count >= 3 ? Int(arguments[2]) ?? 993 : 993
        server = IMAPServer(host: arguments[0], port: port)
        credentials = .password(username: arguments[1], password: readPassword())
    } else {
        print(usage)
        exit(64)
    }

    print("\(server.host):\(server.port) に接続しています…")
    let session = try await IMAPSession.connect(to: server, credentials: credentials)
    print("ログインしました。\n")

    print("■ フォルダ")
    for mailbox in try await session.listMailboxes() {
        let role = mailbox.specialUse.map { " [\($0.rawValue)]" } ?? ""
        print("  \(mailbox.name)\(role)\(mailbox.isSelectable ? "" : " (選択不可)")")
    }

    let status = try await session.examine("INBOX")
    print("\n■ 受信トレイ: \(status.messageCount) 通 (UIDVALIDITY \(status.uidValidity))")
    for header in try await session.fetchLatestHeaders(in: "INBOX", count: 20) {
        let parsed = try MIMEParser.parse(header.headerData)
        let date = parsed.date.map(formatter.string(from:)) ?? "日時不明"
        let sender = parsed.from.first.map { $0.name.isEmpty ? $0.address : $0.name } ?? "差出人不明"
        print("  \(header.isSeen ? " " : "●") \(date)  \(sender)  \(parsed.subject)")
    }
    await session.logout()
} catch {
    print("エラー: \(error)")
    exit(1)
}
