import AccountKit
import Foundation
import MailCore
import Testing
@testable import MailStore

/// 接続のたびに、渡されたサーバー・ログイン情報を記録し、決めた結果を返す。
/// キーチェーンを何回読んだかを数える (読むたびに Mac がパスワードを聞くことがあるため)。
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let base = InMemorySecretStore()
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }

    func data(for key: String) throws -> Data? {
        lock.withLock { reads += 1 }
        return try base.data(for: key)
    }

    func set(_ data: Data?, for key: String) throws {
        try base.set(data, for: key)
    }
}

/// 送信用サーバーへの接続を覚える。
private final class SenderAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(server: SMTPServer, credentials: MailCredentials)] = []
    var list: [(server: SMTPServer, credentials: MailCredentials)] { lock.withLock { storage } }
    func record(_ server: SMTPServer, _ credentials: MailCredentials) { lock.withLock { storage.append((server, credentials)) } }
}

private final class ConnectorSpy: @unchecked Sendable {
    enum Outcome {
        case succeed
        case fail(IMAPError)
    }

    private let lock = NSLock()
    private var outcome: Outcome
    private(set) var attempts: [(server: IMAPServer, credentials: IMAPCredentials)] = []
    let server = FakeMailServer()

    init(_ outcome: Outcome = .succeed) {
        self.outcome = outcome
    }

    var connector: AccountDirectory.Connector {
        { [self] server, credentials in
            let outcome = lock.withLock {
                attempts.append((server, credentials))
                return self.outcome
            }
            switch outcome {
            case .succeed: return self.server
            case let .fail(error): throw error
            }
        }
    }
}

/// `acct-1`、`acct-2`… と順に ID を出す。
private final class IDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.withLock {
            value += 1
            return "acct-\(value)"
        }
    }
}

@Suite struct ProviderChoiceTests {
    @Test func automaticChoiceRecognisesCommonDomains() throws {
        let gmail = try #require(ProviderChoice.automatic.resolve(email: "Me@Gmail.com"))
        #expect(gmail.provider == .gmail)
        #expect(gmail.imap == ServerSettings(host: "imap.gmail.com", port: 993))
        #expect(gmail.smtp == ServerSettings(host: "smtp.gmail.com", port: 465))

        let yahooJapan = try #require(ProviderChoice.automatic.resolve(email: "me@yahoo.co.jp"))
        #expect(yahooJapan.provider == .yahoo)
        #expect(yahooJapan.imap.host == "imap.mail.yahoo.co.jp")

        let yahoo = try #require(ProviderChoice.automatic.resolve(email: "me@yahoo.com"))
        #expect(yahoo.imap.host == "imap.mail.yahoo.com")

        let icloud = try #require(ProviderChoice.automatic.resolve(email: "me@icloud.com"))
        #expect(icloud.provider == .icloud)
        #expect(icloud.imap == ServerSettings(host: "imap.mail.me.com", port: 993))
    }

    @Test func unknownDomainNeedsAnExplicitChoice() {
        #expect(ProviderChoice.automatic.resolve(email: "taro@company.co.jp") == nil)
        // 会社の Google Workspace は「Gmail」を選べば使える
        #expect(ProviderChoice.gmail.resolve(email: "taro@company.co.jp")?.provider == .gmail)
    }
}

@Suite struct AccountDirectoryTests {
    private func makeDirectory(
        _ spy: ConnectorSpy, storage: InMemoryAccountListStorage = InMemoryAccountListStorage(),
        secrets: any SecretStore = InMemorySecretStore()
    ) -> AccountDirectory {
        let counter = IDCounter()
        return AccountDirectory(storage: storage, secrets: secrets, connector: spy.connector, makeID: { counter.next() })
    }

    @Test func addingAnAccountChecksTheLoginThenSavesIt() async throws {
        let spy = ConnectorSpy()
        let storage = InMemoryAccountListStorage()
        let secrets = InMemorySecretStore()
        let directory = makeDirectory(spy, storage: storage, secrets: secrets)

        let account = try await directory.add(
            email: "me@gmail.com", password: "abcd efgh ijkl mnop", displayName: "Gmail (仕事)", choice: .automatic
        )

        #expect(account == Account(id: AccountID("acct-1"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail (仕事)"))
        let attempt = try #require(spy.attempts.first)
        #expect(attempt.server == IMAPServer(host: "imap.gmail.com", port: 993))
        guard case let .password(username, password) = attempt.credentials else {
            Issue.record("expected password credentials")
            return
        }
        #expect(username == "me@gmail.com")
        // Gmail のアプリパスワードは、表示上の空白を取り除いて使う
        #expect(password == "abcdefghijklmnop")
        #expect(await spy.server.calls.contains("LIST"))
        #expect(await spy.server.calls.last == "CLOSE")
        #expect(try secrets.data(for: "password.acct-1") == Data("abcdefghijklmnop".utf8))

        // 保存先から読み直しても同じアカウントが出る (パスワードは一覧に入らない)
        let reopened = makeDirectory(ConnectorSpy(), storage: storage, secrets: secrets)
        #expect(try await reopened.accounts() == [account])
        let saved = String(decoding: try #require(try storage.load()), as: UTF8.self)
        #expect(!saved.contains("abcdefghijklmnop"))
        #expect(try await reopened.settings(for: account.id)?.smtp == ServerSettings(host: "smtp.gmail.com", port: 465))
    }

    @Test func emptyDisplayNameFallsBackToTheAddress() async throws {
        let account = try await makeDirectory(ConnectorSpy()).add(
            email: "me@yahoo.co.jp", password: "pw", displayName: "  ", choice: .automatic
        )
        #expect(account.displayName == "me@yahoo.co.jp")
        #expect(account.provider == .yahoo)
    }

    @Test func wrongPasswordSavesNothing() async throws {
        let spy = ConnectorSpy(.fail(.authenticationFailed("Invalid credentials")))
        let storage = InMemoryAccountListStorage()
        let secrets = InMemorySecretStore()
        let directory = makeDirectory(spy, storage: storage, secrets: secrets)

        await #expect(throws: AccountError.wrongPassword("Invalid credentials")) {
            _ = try await directory.add(email: "me@gmail.com", password: "nope", displayName: "", choice: .automatic)
        }
        #expect(try await directory.accounts().isEmpty)
        #expect(try secrets.data(for: "password.acct-1") == nil)
        #expect(try storage.load() == nil)
    }

    @Test func connectionFailureIsReportedSeparately() async throws {
        let directory = makeDirectory(ConnectorSpy(.fail(.connectionFailed("timeout"))))
        await #expect(throws: AccountError.cannotConnect("timeout")) {
            _ = try await directory.add(email: "me@gmail.com", password: "pw", displayName: "", choice: .automatic)
        }
    }

    @Test func inputIsValidatedBeforeConnecting() async throws {
        let spy = ConnectorSpy()
        let directory = makeDirectory(spy)
        await #expect(throws: AccountError.invalidAddress) {
            _ = try await directory.add(email: "not-an-address", password: "pw", displayName: "", choice: .automatic)
        }
        await #expect(throws: AccountError.emptyPassword) {
            _ = try await directory.add(email: "me@gmail.com", password: "   ", displayName: "", choice: .automatic)
        }
        await #expect(throws: AccountError.unknownProvider) {
            _ = try await directory.add(email: "taro@company.co.jp", password: "pw", displayName: "", choice: .automatic)
        }
        #expect(spy.attempts.isEmpty)
    }

    @Test func sameAddressCannotBeAddedTwice() async throws {
        let directory = makeDirectory(ConnectorSpy())
        _ = try await directory.add(email: "me@gmail.com", password: "pw", displayName: "", choice: .automatic)
        await #expect(throws: AccountError.alreadyAdded) {
            _ = try await directory.add(email: "ME@gmail.com", password: "pw", displayName: "", choice: .automatic)
        }
    }

    @Test func threeGmailAccountsAreKeptInOrder() async throws {
        let directory = makeDirectory(ConnectorSpy())
        for name in ["work", "private", "side"] {
            _ = try await directory.add(email: "\(name)@gmail.com", password: "pw", displayName: name, choice: .automatic)
        }
        #expect(try await directory.accounts().map(\.displayName) == ["work", "private", "side"])
    }

    @Test func removingAnAccountDeletesItsPasswordAndMail() async throws {
        let secrets = InMemorySecretStore()
        let directory = makeDirectory(ConnectorSpy(), secrets: secrets)
        let store = InMemoryMessageStore()
        let account = try await directory.add(email: "me@gmail.com", password: "pw", displayName: "", choice: .automatic)
        try await store.setInboxUnreadCount(3, account: account.id)

        try await directory.remove(account.id, messages: store)

        #expect(try await directory.accounts().isEmpty)
        #expect(try secrets.data(for: "password.\(account.id.rawValue)") == nil)
        #expect(try await store.inboxUnreadCount(account: account.id) == nil)
    }

    /// 送信は、アカウントの送信用サーバー (SMTP) に、保存したパスワードでつなぐ (T18)。
    @Test func openingASenderUsesTheSMTPServerAndTheSavedPassword() async throws {
        let spy = ConnectorSpy()
        let attempts = SenderAttempts()
        let counter = IDCounter()
        let directory = AccountDirectory(
            storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore(), connector: spy.connector,
            senderConnector: { server, credentials in
                attempts.record(server, credentials)
                throw SMTPError.connectionClosed
            },
            makeID: { counter.next() }
        )
        let account = try await directory.add(email: "me@icloud.com", password: "secret", displayName: "", choice: .automatic)

        await #expect(throws: SMTPError.connectionClosed) { _ = try await directory.openSender(for: account.id) }

        let attempt = try #require(attempts.list.last)
        #expect(attempt.server == SMTPServer(host: "smtp.mail.me.com", port: 587))
        #expect(attempt.server.security == .startTLS)
        guard case let .password(username, password) = attempt.credentials else {
            Issue.record("expected password credentials")
            return
        }
        #expect(username == "me@icloud.com")
        #expect(password == "secret")
    }

    /// アプリを開き直したあと、受信・送信を何度しても、キーチェーンを読むのはアカウントごとに 1 回だけ。
    @Test func theKeychainIsReadOncePerAccountPerLaunch() async throws {
        let spy = ConnectorSpy()
        let storage = InMemoryAccountListStorage()
        let secrets = CountingSecretStore()
        let account = try await makeDirectory(spy, storage: storage, secrets: secrets)
            .add(email: "me@yahoo.co.jp", password: "secret", displayName: "", choice: .automatic)

        // 開き直したアプリ (同じ保存先を使う、新しいディレクトリ)
        let relaunched = AccountDirectory(
            storage: storage, secrets: secrets, connector: spy.connector,
            senderConnector: { _, _ in throw SMTPError.connectionClosed }
        )
        let before = secrets.readCount
        for _ in 0..<3 { _ = try await relaunched.openSession(for: account.id) }
        for _ in 0..<2 { _ = try? await relaunched.openSender(for: account.id) }

        #expect(secrets.readCount - before == 1)
        guard case let .password(_, password) = try #require(spy.attempts.last).credentials else {
            Issue.record("expected password credentials")
            return
        }
        #expect(password == "secret")
    }

    /// 削除したアカウントのパスワードは、メモリにも残さない。
    @Test func removedAccountIsForgotten() async throws {
        let spy = ConnectorSpy()
        let directory = makeDirectory(spy)
        let account = try await directory.add(email: "me@yahoo.co.jp", password: "secret", displayName: "", choice: .automatic)
        _ = try await directory.openSession(for: account.id)

        try await directory.remove(account.id, messages: InMemoryMessageStore())

        await #expect(throws: AccountError.notFound) { _ = try await directory.openSession(for: account.id) }
    }

    /// 差出人の名前は、追加するときに入れられ、あとから変えられて、開き直しても残る。
    @Test func senderNameIsSavedAndCanBeChanged() async throws {
        let spy = ConnectorSpy()
        let storage = InMemoryAccountListStorage()
        let directory = makeDirectory(spy, storage: storage)
        let account = try await directory.add(
            email: "me@gmail.com", password: "abcd efgh", displayName: "Gmail (仕事)", senderName: " 山田 太郎 ", choice: .automatic
        )
        #expect(account.senderName == "山田 太郎")

        try await directory.setSenderName("Taro Yamada", for: account.id)
        let reopened = makeDirectory(ConnectorSpy(), storage: storage)
        #expect(try await reopened.accounts().first?.senderName == "Taro Yamada")
        await #expect(throws: AccountError.notFound) { try await directory.setSenderName("x", for: AccountID("none")) }
    }

    @Test func openingASessionUsesTheSavedPassword() async throws {
        let spy = ConnectorSpy()
        let directory = makeDirectory(spy)
        let account = try await directory.add(email: "me@yahoo.co.jp", password: "secret", displayName: "", choice: .automatic)

        _ = try await directory.openSession(for: account.id)

        let attempt = try #require(spy.attempts.last)
        #expect(attempt.server.host == "imap.mail.yahoo.co.jp")
        guard case let .password(_, password) = attempt.credentials else {
            Issue.record("expected password credentials")
            return
        }
        #expect(password == "secret")
    }
}

/// 送信用サーバーへのログインを確かめるための偽物 (T28)。
private struct FakeSender: MailSendingSession {
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {}
    func close() async {}
}

/// 「その他」でサーバー名を手で入れる (T28、US-2)。独自ドメインのメール用。
@Suite struct CustomServerTests {
    private func servers(_ imap: String = "mail.example.jp", _ smtp: String = "smtp.example.jp", port: Int = 587) -> CustomServers {
        CustomServers(imapHost: imap, smtpHost: smtp, smtpPort: port)
    }

    /// 入れたサーバー名は、前後の空白を取って小文字にする。受信は 993 (TLS)、送信は 465 (TLS) か 587 (STARTTLS)。
    @Test func validServersAreAccepted() throws {
        let (imap, smtp) = try servers("  Mail.Example.JP ", "smtp.example.jp", port: 465).validated()
        #expect(imap == ServerSettings(host: "mail.example.jp", port: 993))
        #expect(smtp == ServerSettings(host: "smtp.example.jp", port: 465))
        #expect(try servers(port: 587).validated().1.port == 587)
        #expect(try servers("192.168.1.10", "192.168.1.10").validated().0.host == "192.168.1.10")
    }

    /// 空・空白入り・「https://」付き・ポート付き・点のない名前は、つなぐ前に断る。
    @Test func badServerNamesAreRejected() {
        for bad in ["", "   ", "mail example.jp", "https://mail.example.jp", "mail.example.jp:993", "localhost",
                    "mail..example.jp", ".example.jp", "mail.example.jp.", "-mail.example.jp", "メール.example.jp"] {
            #expect(throws: AccountError.invalidServerName(.incoming), "受信: \(bad)") { try servers(bad).validated() }
            #expect(throws: AccountError.invalidServerName(.outgoing), "送信: \(bad)") { try servers("mail.example.jp", bad).validated() }
        }
    }

    /// 暗号化しないポート (25 など) は選べない。
    @Test func unsupportedPortsAreRejected() {
        for port in [25, 2525, 143, 0, 993] {
            #expect(throws: AccountError.unsupportedPort(port)) { try servers(port: port).validated() }
        }
    }

    /// 「その他」は、入れたサーバーで受信 (IMAP) と送信 (SMTP) の両方にログインできたら保存する。種類は「その他」。
    @Test func addingWithCustomServersChecksBothLogins() async throws {
        let spy = ConnectorSpy()
        let senders = SenderAttempts()
        let storage = InMemoryAccountListStorage()
        let directory = AccountDirectory(
            storage: storage, secrets: InMemorySecretStore(), connector: spy.connector,
            senderConnector: { server, credentials in
                senders.record(server, credentials)
                return FakeSender()
            },
            makeID: { "acct-1" }
        )
        let account = try await directory.add(
            email: "taro@my-shop.jp", password: " secret ", displayName: "お店", choice: .other,
            servers: servers("mail.my-shop.jp", "smtp.my-shop.jp", port: 587)
        )
        #expect(account.provider == .other)
        #expect(spy.attempts.first?.server == IMAPServer(host: "mail.my-shop.jp", port: 993))
        let sender = try #require(senders.list.first)
        #expect(sender.server == SMTPServer(host: "smtp.my-shop.jp", port: 587))
        #expect(sender.server.security == .startTLS)
        guard case let .password(username, password) = sender.credentials else {
            Issue.record("expected password credentials")
            return
        }
        #expect(username == "taro@my-shop.jp" && password == "secret")

        let settings = try #require(try await directory.settings(for: account.id))
        #expect(settings.imap == ServerSettings(host: "mail.my-shop.jp", port: 993))
        #expect(settings.smtp == ServerSettings(host: "smtp.my-shop.jp", port: 587))
        _ = try await directory.openSession(for: account.id)
        #expect(spy.attempts.last?.server.host == "mail.my-shop.jp")
    }

    /// 入れ方が正しくなければ、どこにもつながず、何も保存しない。「その他」でサーバーがなければ断る。
    @Test func badInputConnectsNowhere() async throws {
        let spy = ConnectorSpy()
        let senders = SenderAttempts()
        let storage = InMemoryAccountListStorage()
        let directory = AccountDirectory(
            storage: storage, secrets: InMemorySecretStore(), connector: spy.connector,
            senderConnector: { server, credentials in
                senders.record(server, credentials)
                return FakeSender()
            }
        )
        await #expect(throws: AccountError.unsupportedPort(25)) {
            _ = try await directory.add(email: "taro@my-shop.jp", password: "pw", displayName: "", choice: .other,
                                        servers: servers(port: 25))
        }
        await #expect(throws: AccountError.invalidServerName(.incoming)) {
            _ = try await directory.add(email: "taro@my-shop.jp", password: "pw", displayName: "", choice: .other)
        }
        #expect(spy.attempts.isEmpty && senders.list.isEmpty)
        #expect(try storage.load() == nil)
    }

    /// 送信用サーバーにログインできなければ、保存しない (パスワードも残さない)。
    @Test func failingToLogInToTheSendingServerSavesNothing() async throws {
        let secrets = InMemorySecretStore()
        let storage = InMemoryAccountListStorage()
        for (failure, expected) in [
            (SMTPError.authenticationFailed("535 bad"), AccountError.wrongPassword("535 bad")),
            (SMTPError.encryptionUnavailable, AccountError.cannotConnect("送信サーバーが暗号化 (STARTTLS) に対応していません")),
        ] {
            let directory = AccountDirectory(
                storage: storage, secrets: secrets, connector: ConnectorSpy().connector,
                senderConnector: { _, _ in throw failure }, makeID: { "acct-1" }
            )
            await #expect(throws: expected) {
                _ = try await directory.add(email: "taro@my-shop.jp", password: "pw", displayName: "", choice: .other,
                                            servers: servers())
            }
        }
        #expect(try storage.load() == nil)
        #expect(try secrets.data(for: "password.acct-1") == nil)
    }

    /// 「その他」は自動では選ばれず、ほかの種類ではサーバー名を入れても使わない。
    @Test func otherIsOnlyUsedWhenChosen() async throws {
        #expect(ProviderChoice.other.resolve(email: "taro@my-shop.jp") == nil)
        let spy = ConnectorSpy()
        let directory = AccountDirectory(storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore(),
                                         connector: spy.connector, senderConnector: { _, _ in FakeSender() })
        let account = try await directory.add(email: "me@gmail.com", password: "pw", displayName: "", choice: .automatic,
                                               servers: servers())
        #expect(account.provider == .gmail)
        #expect(spy.attempts.first?.server.host == "imap.gmail.com")
    }
}
