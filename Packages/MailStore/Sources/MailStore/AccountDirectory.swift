import AccountKit
import Foundation
import MailCore

/// 接続先のサーバー。
public struct ServerSettings: Codable, Sendable, Hashable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// 1 つのアカウントの設定。パスワードは含まない (キーチェーンに別に置く)。
public struct MailAccountSettings: Codable, Sendable, Hashable {
    public var account: Account
    public var imap: ServerSettings
    /// 送信用。T17 で使う。
    public var smtp: ServerSettings
}

/// アカウント追加の画面で選ぶ「メールの種類」。`automatic` はアドレスのドメインから判断する。
public enum ProviderChoice: String, CaseIterable, Sendable {
    case automatic
    /// Gmail と、会社などの Google Workspace (独自ドメインの Gmail)。
    case gmail
    case yahooJapan
    case yahoo
    case icloud

    public struct Resolved: Sendable, Hashable {
        public var provider: MailProvider
        public var imap: ServerSettings
        public var smtp: ServerSettings
    }

    /// 使うサーバーを決める。`automatic` でドメインに覚えがなければ nil (画面で種類を選んでもらう)。
    public func resolve(email: String) -> Resolved? {
        switch self {
        case .automatic:
            return Self.guess(domain: email.split(separator: "@").last.map { $0.lowercased() } ?? "")?.resolve(email: email)
        case .gmail:
            return Resolved(provider: .gmail, imap: .init(host: "imap.gmail.com", port: 993), smtp: .init(host: "smtp.gmail.com", port: 465))
        case .yahooJapan:
            return Resolved(
                provider: .yahoo,
                imap: .init(host: "imap.mail.yahoo.co.jp", port: 993),
                smtp: .init(host: "smtp.mail.yahoo.co.jp", port: 465)
            )
        case .yahoo:
            return Resolved(
                provider: .yahoo, imap: .init(host: "imap.mail.yahoo.com", port: 993), smtp: .init(host: "smtp.mail.yahoo.com", port: 465)
            )
        case .icloud:
            // iCloud の送信は 587 (STARTTLS) だけ。送信 (T17) で STARTTLS に対応する
            return Resolved(provider: .icloud, imap: .init(host: "imap.mail.me.com", port: 993), smtp: .init(host: "smtp.mail.me.com", port: 587))
        }
    }

    private static func guess(domain: String) -> ProviderChoice? {
        switch domain {
        case "gmail.com", "googlemail.com": .gmail
        case "yahoo.co.jp": .yahooJapan
        case "icloud.com", "me.com", "mac.com": .icloud
        case _ where domain.hasPrefix("yahoo.") || domain == "ymail.com" || domain == "rocketmail.com": .yahoo
        default: nil
        }
    }
}

public enum AccountError: Error, Equatable, Sendable {
    case invalidAddress
    case emptyPassword
    /// アドレスからメールの種類が分からない。画面で種類を選んでもらう。
    case unknownProvider
    case alreadyAdded
    /// ログインできない (パスワードが違う、アプリパスワードではない、IMAP が無効、など)。
    case wrongPassword(String)
    case cannotConnect(String)
    case notFound
    case storage(String)
}

/// アカウント一覧の保存先 (パスワードは入れない)。アプリでは UserDefaults。
public protocol AccountListStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public struct UserDefaultsAccountListStorage: AccountListStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "accounts.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() throws -> Data? {
        defaults.data(forKey: key)
    }

    public func save(_ data: Data) throws {
        defaults.set(data, forKey: key)
    }
}

/// テスト用。
public final class InMemoryAccountListStorage: AccountListStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    public init() {}

    public func load() throws -> Data? {
        lock.withLock { data }
    }

    public func save(_ data: Data) throws {
        lock.withLock { self.data = data }
    }
}

/// 登録しているアカウントの管理。追加するときは、実際にログインできることを確かめてから保存する。
public actor AccountDirectory {
    public typealias Connector = @Sendable (IMAPServer, IMAPCredentials) async throws -> any MailServerSession
    public typealias SenderConnector = @Sendable (SMTPServer, MailCredentials) async throws -> any MailSendingSession

    /// アプリで使う送信: 本物の SMTP。
    public static let smtpConnector: SenderConnector = { server, credentials in
        try await SMTPSession.connect(to: server, credentials: credentials)
    }

    /// アプリで使う接続: 本物の IMAP。
    public static let imapConnector: Connector = { server, credentials in
        try await IMAPSession.connect(to: server, credentials: credentials)
    }

    private let storage: any AccountListStorage
    private let secrets: any SecretStore
    private let connector: Connector
    private let senderConnector: SenderConnector
    private let makeID: @Sendable () -> String
    /// 一度キーチェーンから読んだパスワード (アプリを閉じるまでメモリにだけ置く)。
    /// 受信・本文・送信のたびにキーチェーンを読むと、そのたびに「キーチェーンを使おうとしています」と聞かれるため。
    private var passwordCache: [AccountID: String] = [:]

    public init(
        storage: any AccountListStorage,
        secrets: any SecretStore,
        connector: @escaping Connector = AccountDirectory.imapConnector,
        senderConnector: @escaping SenderConnector = AccountDirectory.smtpConnector,
        makeID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.storage = storage
        self.secrets = secrets
        self.connector = connector
        self.senderConnector = senderConnector
        self.makeID = makeID
    }

    public func accounts() throws -> [Account] {
        try loadSettings().map(\.account)
    }

    public func settings(for id: AccountID) throws -> MailAccountSettings? {
        try loadSettings().first { $0.account.id == id }
    }

    /// ログインを確かめてから、アカウントを保存する。失敗したら何も保存しない。
    public func add(
        email rawEmail: String, password rawPassword: String, displayName: String, senderName: String = "", choice: ProviderChoice
    ) async throws(AccountError) -> Account {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeAddress(email) else { throw .invalidAddress }
        guard let resolved = choice.resolve(email: email) else { throw .unknownProvider }
        // Gmail のアプリパスワードは 4 文字ずつ空白で区切って表示されるので、空白を除く
        let password = resolved.provider == .gmail
            ? rawPassword.filter { !$0.isWhitespace }
            : rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw .emptyPassword }

        var list: [MailAccountSettings]
        do {
            list = try loadSettings()
        } catch {
            throw .storage(String(describing: error))
        }
        guard !list.contains(where: { $0.account.emailAddress.lowercased() == email.lowercased() }) else {
            throw .alreadyAdded
        }

        // 実際にログインして、フォルダ一覧が取れることを確かめる
        let server = IMAPServer(host: resolved.imap.host, port: resolved.imap.port)
        do {
            let session = try await connector(server, .password(username: email, password: password))
            _ = try await session.listMailboxes()
            await session.close()
        } catch let error as IMAPError {
            switch error {
            case let .authenticationFailed(reason): throw .wrongPassword(reason)
            case let .connectionFailed(reason): throw .cannotConnect(reason)
            default: throw .cannotConnect(error.description)
            }
        } catch {
            throw .cannotConnect(String(describing: error))
        }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(
            id: AccountID(makeID()), provider: resolved.provider, emailAddress: email, displayName: name.isEmpty ? email : name,
            senderName: Self.cleanSenderName(senderName)
        )
        list.append(MailAccountSettings(account: account, imap: resolved.imap, smtp: resolved.smtp))
        do {
            try secrets.set(Data(password.utf8), for: Self.passwordKey(account.id))
            passwordCache[account.id] = password
            try save(list)
        } catch {
            try? secrets.set(nil, for: Self.passwordKey(account.id))
            throw .storage(String(describing: error))
        }
        return account
    }

    /// アカウントを削除する。パスワードと、保存していたメールも消す。
    public func remove(_ id: AccountID, messages: any MessageStore) async throws {
        let list = try loadSettings().filter { $0.account.id != id }
        try save(list)
        passwordCache[id] = nil
        try secrets.set(nil, for: Self.passwordKey(id))
        try await messages.deleteAccount(id)
    }

    /// 差出人の名前を変える (送ったメールで相手に見える名前)。
    public func setSenderName(_ name: String, for id: AccountID) throws(AccountError) {
        var list: [MailAccountSettings]
        do {
            list = try loadSettings()
        } catch {
            throw .storage(String(describing: error))
        }
        guard let index = list.firstIndex(where: { $0.account.id == id }) else { throw .notFound }
        list[index].account.senderName = Self.cleanSenderName(name)
        do {
            try save(list)
        } catch {
            throw .storage(String(describing: error))
        }
    }

    /// 前後の空白と改行を取る (改行はヘッダーに入れられないため)。
    static func cleanSenderName(_ name: String) -> String {
        name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// 保存したパスワードでサーバーに接続する (同期に使う)。
    public func openSession(for id: AccountID) async throws -> any MailServerSession {
        let (settings, credentials) = try savedCredentials(for: id)
        return try await connector(IMAPServer(host: settings.imap.host, port: settings.imap.port), credentials)
    }

    /// 保存したパスワードで、送信用のサーバー (SMTP) に接続する。
    public func openSender(for id: AccountID) async throws -> any MailSendingSession {
        let (settings, credentials) = try savedCredentials(for: id)
        return try await senderConnector(SMTPServer(host: settings.smtp.host, port: settings.smtp.port), credentials)
    }

    private func savedCredentials(for id: AccountID) throws -> (MailAccountSettings, MailCredentials) {
        guard let settings = try settings(for: id) else { throw AccountError.notFound }
        return (settings, .password(username: settings.account.emailAddress, password: try password(for: id)))
    }

    /// パスワード。キーチェーンを読むのは、アプリを開いてからアカウントごとに 1 回だけ。
    private func password(for id: AccountID) throws -> String {
        if let cached = passwordCache[id] { return cached }
        guard let data = try secrets.data(for: Self.passwordKey(id)) else {
            throw AccountError.wrongPassword("パスワードが保存されていません")
        }
        let password = String(decoding: data, as: UTF8.self)
        passwordCache[id] = password
        return password
    }

    // MARK: - 部品

    static func passwordKey(_ id: AccountID) -> String {
        "password.\(id.rawValue)"
    }

    private static func looksLikeAddress(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !email.contains(" ")
    }

    private func loadSettings() throws -> [MailAccountSettings] {
        guard let data = try storage.load() else { return [] }
        return try JSONDecoder().decode([MailAccountSettings].self, from: data)
    }

    private func save(_ list: [MailAccountSettings]) throws {
        try storage.save(JSONEncoder().encode(list))
    }
}
