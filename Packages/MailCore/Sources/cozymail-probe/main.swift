import Foundation
import MailCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 実際のメールサーバーにつないで、フォルダ一覧と受信トレイの最新 20 通の件名を表示する確認用のツール。
///
/// 使い方:
///   swift run --package-path Packages/MailCore cozymail-probe <IMAP サーバー> <メールアドレス> [ポート]
///
/// パスワード (アプリパスワード) は、環境変数 COZYMAIL_PASSWORD があればそれを使い、なければ入力を求める。
/// パスワードは画面にも記録にも出さない。

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    print("使い方: cozymail-probe <IMAP サーバー> <メールアドレス> [ポート]")
    print("例:     cozymail-probe imap.mail.yahoo.co.jp you@yahoo.co.jp")
    exit(64)
}
let host = arguments[arguments.startIndex]
let username = arguments[arguments.startIndex + 1]
let port = arguments.count >= 3 ? Int(arguments[arguments.startIndex + 2]) ?? 993 : 993

func readPassword() -> String {
    if let fromEnvironment = ProcessInfo.processInfo.environment["COZYMAIL_PASSWORD"], !fromEnvironment.isEmpty {
        return fromEnvironment
    }
    guard let entered = getpass("アプリパスワード: ") else { return "" }
    return String(cString: entered)
}

let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd HH:mm"

do {
    print("\(host):\(port) に接続しています…")
    let session = try await IMAPSession.connect(
        to: IMAPServer(host: host, port: port),
        credentials: .password(username: username, password: readPassword())
    )
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
