import Foundation

/// 接続先の SMTP サーバー。暗号化なしの接続は作れない。
public struct SMTPServer: Sendable, Hashable {
    public enum Security: Sendable, Hashable {
        /// 接続した直後から TLS で暗号化する (ポート 465)。
        case tls
        /// 平文で接続し、すぐ `STARTTLS` で暗号化に切り替える (ポート 587)。
        /// サーバーが `STARTTLS` に対応していなければ、ログインせずにやめる。
        case startTLS
        /// テスト専用。暗号化しない。アプリからは作れない (`internal`)。
        case plaintextForTesting
    }

    public let host: String
    public let port: Int
    public let security: Security

    /// ポート 465 なら最初から TLS、それ以外 (587 など) は STARTTLS。どちらも暗号化される。
    public init(host: String, port: Int) {
        self.init(host: host, port: port, security: port == 465 ? .tls : .startTLS)
    }

    init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// SMTP の返事 1 つ (複数行のこともある)。
struct SMTPReply: Sendable, Equatable {
    /// 3 桁の番号 (例: 250)。
    let code: Int
    /// 番号のあとの文 (行ごと)。
    let lines: [String]

    var text: String { lines.joined(separator: " ") }
    var isPositive: Bool { (200..<400).contains(code) }
}

public enum SMTPError: Error, Equatable, CustomStringConvertible {
    /// サーバーにつながらない (名前が引けない、拒否された、TLS の失敗など)。
    case connectionFailed(String)
    /// STARTTLS が使えないサーバー。暗号化なしでは送らない。
    case encryptionUnavailable
    /// ユーザー名やパスワード (アプリパスワード) が違う。
    case authenticationFailed(String)
    /// サーバーが、このアプリが使えるログイン方法に対応していない。
    case authenticationUnsupported
    /// 宛先をサーバーが受け付けなかった。
    case recipientRejected(address: String, reason: String)
    /// サーバーが命令を断った。
    case commandFailed(String)
    /// 宛先がない。
    case noRecipients
    /// 途中で接続が切れた。
    case connectionClosed
    /// サーバーから返事が来ない。
    case timedOut
    /// 返事の形が想定外。
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case let .connectionFailed(reason): "送信用のサーバーに接続できませんでした: \(reason)"
        case .encryptionUnavailable: "送信用のサーバーが暗号化に対応していないため、送りませんでした"
        case let .authenticationFailed(reason): "送信用のサーバーにログインできませんでした: \(reason)"
        case .authenticationUnsupported: "送信用のサーバーが、このアプリのログイン方法に対応していません"
        case let .recipientRejected(address, reason): "宛先 \(address) をサーバーが受け付けませんでした: \(reason)"
        case let .commandFailed(reason): "サーバーが送信を断りました: \(reason)"
        case .noRecipients: "宛先がありません"
        case .connectionClosed: "送信用のサーバーとの接続が切れました"
        case .timedOut: "送信用のサーバーから返事がありませんでした"
        case let .unexpectedResponse(reason): "送信用のサーバーの返事を読めませんでした: \(reason)"
        }
    }
}

/// ログインに使う情報。受信 (IMAP) と送信 (SMTP) で同じものを使う。
public typealias MailCredentials = IMAPCredentials
