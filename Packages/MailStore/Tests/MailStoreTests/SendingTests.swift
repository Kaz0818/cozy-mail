import Foundation
import MailCore
import Testing
@testable import MailStore

/// 送信用のサーバー (SMTP) の代わり。送ったものを覚える。
private actor FakeSender: MailSendingSession {
    struct Sent {
        let data: Data
        let from: String
        let recipients: [String]
    }

    private(set) var sent: [Sent] = []
    private(set) var closed = 0
    private let failure: SMTPError?

    init(failure: SMTPError? = nil) {
        self.failure = failure
    }

    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        if let failure { throw failure }
        sent.append(Sent(data: message, from: sender, recipients: recipients))
    }

    func close() async {
        closed += 1
    }
}

/// 送信と、返信のための元のメール (T18)。
@Suite struct SendingTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")
    private let tanaka = Contact(name: "田中 健一", address: "k.tanaka@example.com")

    private func server(withSent: Bool = true) async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        if withSent { await server.addFolder("Sent", specialUse: .sent) }
        await server.add(.init(uid: 11, date: now.addingTimeInterval(-3600), subject: "hello", from: "a@example.com"), to: "INBOX")
        return server
    }

    private func repository(
        account: Account, server: FakeMailServer, sender: FakeSender?, fetchMessage: LiveMailRepository.MessageFetcher? = nil
    ) async throws -> (LiveMailRepository, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        let now = now
        _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
        let accounts = [account]
        let repository = LiveMailRepository(
            store: store,
            accounts: { accounts },
            fetchMessage: fetchMessage,
            openSession: { _ in server },
            openSender: sender.map { sender in { @Sendable _ in sender } },
            now: { now }
        )
        return (repository, store)
    }

    private func draft(_ account: Account) -> Draft {
        Draft(
            accountID: account.id,
            to: [tanaka],
            cc: [Contact(name: "", address: "sato@example.org")],
            bcc: [Contact(name: "", address: "boss@example.com")],
            subject: "日程の件",
            body: "よろしくお願いします。\n",
            inReplyTo: "orig@example.com",
            references: ["orig@example.com"]
        )
    }

    @Test func sendsToEveryRecipientAndSavesToSentOutsideGmail() async throws {
        let server = await server()
        let sender = FakeSender()
        let (repository, _) = try await repository(account: yahoo, server: server, sender: sender)

        let outcome = try await repository.send(draft(yahoo))

        #expect(outcome == .sent)
        let sent = try #require(await sender.sent.first)
        #expect(sent.from == "me@yahoo.example")
        #expect(sent.recipients == ["k.tanaka@example.com", "sato@example.org", "boss@example.com"])
        let parsed = try MIMEParser.parse(sent.data)
        #expect(parsed.subject == "日程の件")
        #expect(parsed.from == [EmailAddress(name: "", address: "me@yahoo.example")])
        #expect(parsed.inReplyTo == "orig@example.com")
        #expect(parsed.date == now)
        #expect(await sender.closed == 1)

        // 「送信済み」に、送ったものと同じメールが 1 通だけ入る
        let appended = await server.appended
        #expect(appended.count == 1)
        #expect(appended.first?.folder == "Sent")
        #expect(appended.first?.data == sent.data)
        #expect(await server.calls.contains("APPEND Sent [\"\\\\Seen\"]"))
    }

    /// Gmail は自動で「送信済み」に入れるので、APPEND すると 2 通になってしまう。
    @Test func gmailIsNotAppendedTwice() async throws {
        let server = await server()
        let sender = FakeSender()
        let (repository, _) = try await repository(account: gmail, server: server, sender: sender)

        #expect(try await repository.send(draft(gmail)) == .sent)
        #expect(await sender.sent.count == 1)
        #expect(await server.appended.isEmpty)
    }

    @Test func problemsStopBeforeConnecting() async throws {
        let server = await server()
        let sender = FakeSender()
        let (repository, _) = try await repository(account: yahoo, server: server, sender: sender)
        var bad = draft(yahoo)
        bad.to = []
        bad.cc = []
        bad.bcc = []

        await #expect(throws: DraftProblem.noRecipients) { try await repository.send(bad) }
        #expect(await sender.closed == 0)
    }

    @Test func failedSendIsReportedAndNothingIsSaved() async throws {
        let server = await server()
        let sender = FakeSender(failure: .recipientRejected(address: "k.tanaka@example.com", reason: "No such user"))
        let (repository, _) = try await repository(account: yahoo, server: server, sender: sender)

        await #expect(throws: SMTPError.recipientRejected(address: "k.tanaka@example.com", reason: "No such user")) {
            try await repository.send(draft(yahoo))
        }
        #expect(await sender.closed == 1)
        #expect(await server.appended.isEmpty)
    }

    /// 送れたが「送信済み」がない: 送信は成功として、残せなかったことだけ知らせる (もう一度送らせない)。
    @Test func sentButNotSavedWhenThereIsNoSentFolder() async throws {
        let server = await server(withSent: false)
        let sender = FakeSender()
        let (repository, _) = try await repository(account: yahoo, server: server, sender: sender)

        let outcome = try await repository.send(draft(yahoo))

        guard case .sentButNotSaved = outcome else {
            Issue.record("送信済みに残せなかったことが知らされない: \(outcome)")
            return
        }
        #expect(await sender.sent.count == 1)
    }

    @Test func sendingFromAnUnknownAccountIsRefused() async throws {
        let server = await server()
        let (repository, _) = try await repository(account: yahoo, server: server, sender: FakeSender())
        var other = draft(yahoo)
        other.accountID = AccountID("removed")
        await #expect(throws: DraftProblem.noAccount) { try await repository.send(other) }
    }

    @Test func replySourceComesFromTheWholeMessage() async throws {
        let server = await server()
        let raw = """
        From: 田中 健一 <k.tanaka@example.com>\r
        Reply-To: list@example.com\r
        To: me@yahoo.example, sato@example.org\r
        Cc: suzuki@example.net\r
        Subject: =?UTF-8?B?5pel56iL44Gu5Lu2?=\r
        Date: Fri, 13 Nov 2026 14:05:00 +0900\r
        Message-ID: <orig@example.com>\r
        References: <root@example.com>\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        本文です。\r

        """
        let (repository, store) = try await repository(
            account: yahoo, server: server, sender: nil, fetchMessage: { _ in Data(raw.utf8) }
        )
        let id = try #require(try await store.messages(account: yahoo.id, mailbox: "INBOX").first?.summary.id)

        let source = try await repository.replySource(for: id)

        #expect(source.accountID == yahoo.id)
        #expect(source.from == [tanaka])
        #expect(source.replyTo == [Contact(name: "", address: "list@example.com")])
        #expect(source.to.map(\.address) == ["me@yahoo.example", "sato@example.org"])
        #expect(source.cc.map(\.address) == ["suzuki@example.net"])
        #expect(source.subject == "日程の件")
        #expect(source.messageID == "orig@example.com")
        #expect(source.references == ["root@example.com"])
        #expect(source.text.contains("本文です。"))

        let reply = Composer.draft(.reply, replyingTo: source, myAddresses: ["me@yahoo.example"], defaultAccount: nil)
        #expect(reply.to == [Contact(name: "", address: "list@example.com")])
        #expect(reply.references == ["root@example.com", "orig@example.com"])
    }

    @Test func samplesCanBeRepliedToButNotSent() async throws {
        let repository = PreviewMailRepository()
        let first = try #require(try await repository.messages(in: .unified(.inbox), filter: .all).first)
        let source = try await repository.replySource(for: first.id)
        #expect(source.from == [first.sender])
        await #expect(throws: MailRepositoryError.actionUnavailable) {
            try await repository.send(Draft(accountID: first.accountID, to: [tanaka]))
        }
    }
}
