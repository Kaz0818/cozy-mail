import Foundation

/// 接続先の IMAP サーバー。
public struct IMAPServer: Sendable, Hashable {
    public enum Security: Sendable, Hashable {
        /// 接続した直後から TLS で暗号化する (ポート 993)。
        case tls
        /// テスト専用。暗号化しない。アプリからは作れない (`internal`)。
        case plaintextForTesting
    }

    public let host: String
    public let port: Int
    public let security: Security

    /// 暗号化なしの接続はできないよう、公開の初期化は TLS だけにする。
    public init(host: String, port: Int = 993) {
        self.init(host: host, port: port, security: .tls)
    }

    init(host: String, port: Int, security: Security) {
        self.host = host
        self.port = port
        self.security = security
    }
}

/// ログインに使う情報。パスワードは説明文 (`description`) に出さない。
public enum IMAPCredentials: Sendable, CustomStringConvertible {
    case password(username: String, password: String)

    public var username: String {
        switch self {
        case let .password(username, _): username
        }
    }

    public var description: String {
        "IMAPCredentials(\(username), <redacted>)"
    }
}

/// フォルダの役割 (RFC 6154 SPECIAL-USE)。受信トレイは名前で判定する。
public enum IMAPSpecialUse: String, Sendable, Hashable {
    case inbox
    case all
    case archive
    case drafts
    case flagged
    case junk
    case sent
    case trash
}

public struct IMAPMailbox: Sendable, Hashable {
    /// 表示用の名前 (階層は区切り文字でつないだまま。修正 UTF-7 は解除済み)。
    public var name: String
    /// サーバーに送るときの名前 (修正 UTF-7 のまま)。
    public var rawName: String
    public var separator: Character?
    public var specialUse: IMAPSpecialUse?
    /// `\Noselect` が付いたフォルダ (階層の入れ物だけで、メールは入らない) は false。
    public var isSelectable: Bool
}

public struct IMAPMailboxStatus: Sendable, Hashable {
    public var messageCount: Int
    public var uidValidity: UInt32
    public var uidNext: UInt32?

    public init(messageCount: Int, uidValidity: UInt32, uidNext: UInt32?) {
        self.messageCount = messageCount
        self.uidValidity = uidValidity
        self.uidNext = uidNext
    }
}

/// `FETCH` で取った 1 通分の見出し。
public struct IMAPFetchedHeader: Sendable, Hashable {
    public var uid: UInt32
    public var flags: [String]
    public var size: Int?
    /// ヘッダー部分の生データ。`MIMEParser.parse` で読める。
    public var headerData: Data

    public var isSeen: Bool {
        flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }
}

public enum IMAPError: Error, Equatable, CustomStringConvertible {
    /// サーバーにつながらない (名前が引けない、拒否された、TLS の失敗など)。
    case connectionFailed(String)
    /// ユーザー名やパスワードが違う。
    case authenticationFailed(String)
    /// サーバーが命令を断った (`NO` / `BAD`)。
    case commandFailed(String)
    /// 途中で接続が切れた。
    case connectionClosed
    /// 応答の形が想定外。
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case let .connectionFailed(reason): "サーバーに接続できませんでした: \(reason)"
        case let .authenticationFailed(reason): "ログインできませんでした: \(reason)"
        case let .commandFailed(reason): "サーバーが処理を断りました: \(reason)"
        case .connectionClosed: "サーバーとの接続が切れました"
        case let .unexpectedResponse(reason): "サーバーの応答を読めませんでした: \(reason)"
        }
    }
}
