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
