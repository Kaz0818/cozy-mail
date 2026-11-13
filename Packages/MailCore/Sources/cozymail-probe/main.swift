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
/// 送信の確認 (自分のアドレスに、日本語の件名・本文・添付つきのテストメールを 1 通送る):
///   swift run --package-path Packages/MailCore cozymail-probe send <SMTP サーバー> <メールアドレス> [ポート]
///   ポートを省くと 465 (最初から暗号化)。587 なら STARTTLS で暗号化する。
///
/// パスワードやトークンは画面にも記録にも出さない。

let usage = """
使い方:
  cozymail-probe <IMAP サーバー> <メールアドレス> [ポート]
  cozymail-probe --gmail [メールアドレス]
  cozymail-probe send <SMTP サーバー> <メールアドレス> [ポート]
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

/// 自分宛てにテストメールを送る。
func sendTestMail(host: String, address: String, port: Int) async throws {
    let server = SMTPServer(host: host, port: port)
    print("\(server.host):\(server.port) に接続しています (\(server.security == .tls ? "最初から暗号化" : "STARTTLS で暗号化"))…")
    let session = try await SMTPSession.connect(to: server, credentials: .password(username: address, password: readPassword()))
    print("ログインしました。")
    let me = EmailAddress(name: "Cozy Mail テスト", address: address)
    let message = OutgoingMessage(
        from: me,
        to: [me],
        subject: "Cozy Mail からのテスト送信 ✉️",
        textBody: "これは Cozy Mail の確認用ツールから送ったテストメールです。\n日本語の件名・本文・添付ファイルが正しく読めれば成功です。\n",
        attachments: [OutgoingAttachment(filename: "テスト.txt", mimeType: "text/plain", data: Data("添付ファイルのテストです。\n".utf8))],
        messageID: MIMEBuilder.makeMessageID(for: me)
    )
    try await session.send(try MIMEBuilder.build(message), from: address, to: message.envelopeRecipients)
    await session.quit()
    print("送りました。\(address) の受信トレイを確かめてください。")
}

if arguments.first == "send" {
    guard arguments.count >= 3 else {
        print(usage)
        exit(64)
    }
    do {
        let port = arguments.count >= 4 ? Int(arguments[3]) ?? 465 : 465
        try await sendTestMail(host: arguments[1], address: arguments[2], port: port)
        exit(0)
    } catch {
        print("エラー: \(error)")
        exit(1)
    }
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
