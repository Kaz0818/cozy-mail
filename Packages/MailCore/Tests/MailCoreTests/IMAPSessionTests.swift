import Foundation
import Testing
@testable import MailCore

/// よくある応答をまとめた偽サーバーの台本。
@Sendable private func standardScript(_ command: String) -> [String] {
    let upper = command.uppercased()
    if upper.hasPrefix("LOGIN") {
        if command.contains("wrong") {
            return ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials"]
        }
        return ["TAG OK [CAPABILITY IMAP4rev1 SPECIAL-USE] Logged in"]
    }
    if upper.hasPrefix("LIST") {
        return [
            #"* LIST (\HasNoChildren) "/" "INBOX""#,
            #"* LIST (\HasNoChildren \Sent) "/" "Sent""#,
            #"* LIST (\HasNoChildren \Drafts) "/" "Drafts""#,
            #"* LIST (\HasNoChildren \Junk) "/" "Bulk Mail""#,
            #"* LIST (\HasNoChildren \Trash) "/" "Trash""#,
            #"* LIST (\HasNoChildren \Archive) "/" "Archive""#,
            #"* LIST (\Noselect \HasChildren) "/" "[Gmail]""#,
            #"* LIST (\HasNoChildren \All) "/" "[Gmail]/&MFkweTBmMG4w4TD8MOs-""#,
            "TAG OK LIST completed",
        ]
    }
    if upper.hasPrefix("SELECT") || upper.hasPrefix("EXAMINE") {
        return [
            "* 3 EXISTS",
            "* 0 RECENT",
            "* OK [UIDVALIDITY 1234] UIDs valid",
            "* OK [UIDNEXT 104] Predicted next UID",
            "TAG OK [READ-ONLY] EXAMINE completed",
        ]
    }
    if upper.hasPrefix("FETCH") || upper.hasPrefix("UID FETCH") {
        let header1 = "Subject: =?UTF-8?B?5LyB55S7?=\r\nFrom: a@example.com\r\n\r\n"
        let header2 = "Subject: second\r\n\r\n"
        let size1 = header1.utf8.count
        let size2 = header2.utf8.count
        return [
            "* 2 FETCH (UID 102 FLAGS (\\Seen) RFC822.SIZE 2048 BODY[HEADER] {\(size1)}\r\n\(header1))",
            "* 3 FETCH (UID 103 FLAGS () RFC822.SIZE 512 BODY[HEADER] {\(size2)}\r\n\(header2))",
            "TAG OK FETCH completed",
        ]
    }
    if upper.hasPrefix("LOGOUT") {
        return ["* BYE Logging out", "TAG OK LOGOUT completed"]
    }
    return ["TAG BAD Unknown command"]
}

@Suite(.serialized) struct IMAPSessionTests {
    private func withServer<T>(
        _ script: @escaping FakeIMAPServer.Responder = standardScript,
        _ body: (FakeIMAPServer) async throws -> T
    ) async throws -> T {
        let server = try await FakeIMAPServer(respond: script)
        do {
            let result = try await body(server)
            await server.shutdown()
            return result
        } catch {
            await server.shutdown()
            throw error
        }
    }

    private func connect(_ server: FakeIMAPServer, password: String = "secret") async throws -> IMAPSession {
        try await IMAPSession.connect(
            to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
            credentials: .password(username: "me@example.com", password: password)
        )
    }

    @Test func logsInAndListsMailboxesWithSpecialUse() async throws {
        try await withServer { server in
            let session = try await connect(server)
            let mailboxes = try await session.listMailboxes()
            await session.logout()

            #expect(mailboxes.map(\.name) == [
                "INBOX", "Sent", "Drafts", "Bulk Mail", "Trash", "Archive", "[Gmail]", "[Gmail]/すべてのメール",
            ])
            #expect(mailboxes.map(\.specialUse) == [
                .inbox, .sent, .drafts, .junk, .trash, .archive, nil, .all,
            ])
            #expect(mailboxes.first { $0.name == "[Gmail]" }?.isSelectable == false)
            #expect(server.receivedCommands.first == #"LOGIN "me@example.com" "secret""#)
        }
    }

    @Test func examinesMailboxAndReadsStatus() async throws {
        try await withServer { server in
            let session = try await connect(server)
            let status = try await session.examine("INBOX")
            await session.logout()

            #expect(status == IMAPMailboxStatus(messageCount: 3, uidValidity: 1234, uidNext: 104))
        }
    }

    @Test func fetchesLatestHeadersNewestFirst() async throws {
        try await withServer { server in
            let session = try await connect(server)
            let headers = try await session.fetchLatestHeaders(in: "INBOX", count: 2)
            await session.logout()

            #expect(headers.map(\.uid) == [103, 102])
            #expect(headers.map(\.isSeen) == [false, true])
            #expect(headers.map(\.size) == [512, 2048])
            let first = try MIMEParser.parse(headers[1].headerData)
            #expect(first.subject == "企画")
            #expect(server.receivedCommands.contains { $0.hasPrefix("FETCH 2:3 ") })
        }
    }

    @Test func emptyMailboxFetchesNothing() async throws {
        let script: FakeIMAPServer.Responder = { command in
            if command.uppercased().hasPrefix("EXAMINE") {
                return ["* 0 EXISTS", "* OK [UIDVALIDITY 1] ok", "TAG OK done"]
            }
            return standardScript(command)
        }
        try await withServer(script) { server in
            let session = try await connect(server)
            let headers = try await session.fetchLatestHeaders(in: "INBOX", count: 20)
            await session.logout()
            #expect(headers.isEmpty)
            #expect(!server.receivedCommands.contains { $0.hasPrefix("FETCH") })
        }
    }

    @Test func wrongPasswordThrowsAuthenticationFailedWithoutLeakingThePassword() async throws {
        try await withServer { server in
            let error = await #expect(throws: IMAPError.self) {
                _ = try await connect(server, password: "wrong-pass-123")
            }
            guard case let .authenticationFailed(message) = error else {
                Issue.record("expected authenticationFailed, got \(String(describing: error))")
                return
            }
            #expect(message.contains("Invalid credentials"))
            #expect(!String(describing: error).contains("wrong-pass-123"))
        }
    }

    @Test func failedCommandThrowsCommandFailed() async throws {
        let script: FakeIMAPServer.Responder = { command in
            if command.uppercased().hasPrefix("EXAMINE") { return ["TAG NO [NONEXISTENT] No such mailbox"] }
            return standardScript(command)
        }
        try await withServer(script) { server in
            let session = try await connect(server)
            await #expect(throws: IMAPError.commandFailed("No such mailbox")) {
                _ = try await session.examine("Missing")
            }
            await session.logout()
        }
    }

    @Test func connectionRefusedThrowsConnectionFailed() async throws {
        let server = try await FakeIMAPServer(respond: standardScript)
        let port = server.port
        await server.shutdown()
        await #expect {
            _ = try await IMAPSession.connect(
                to: IMAPServer(host: "127.0.0.1", port: port, security: .plaintextForTesting),
                credentials: .password(username: "a", password: "b")
            )
        } throws: { error in
            guard case .connectionFailed = error as? IMAPError else { return false }
            return true
        }
    }

    @Test func xoauth2SendsTheBearerTokenAsInitialResponse() async throws {
        let script: FakeIMAPServer.Responder = { command in
            if command.uppercased().hasPrefix("AUTHENTICATE XOAUTH2") { return ["TAG OK Success"] }
            return standardScript(command)
        }
        try await withServer(script) { server in
            let session = try await IMAPSession.connect(
                to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
                credentials: .oauth2(username: "me@gmail.com", accessToken: "ya29.token")
            )
            await session.logout()
            let expected = Data("user=me@gmail.com\u{01}auth=Bearer ya29.token\u{01}\u{01}".utf8).base64EncodedString()
            #expect(server.receivedCommands.first == "AUTHENTICATE XOAUTH2 \(expected)")
        }
    }

    @Test func xoauth2FailureAnswersTheChallengeAndThrowsAuthenticationFailed() async throws {
        let errorJSON = Data(#"{"status":"400","schemes":"Bearer","scope":"https://mail.google.com/"}"#.utf8)
        let script: FakeIMAPServer.Responder = { command in
            if command.uppercased().hasPrefix("AUTHENTICATE XOAUTH2") { return ["+ \(errorJSON.base64EncodedString())"] }
            if command.hasPrefix("<continuation>") { return ["TAG NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)"] }
            return standardScript(command)
        }
        try await withServer(script) { server in
            let error = await #expect(throws: IMAPError.self) {
                _ = try await IMAPSession.connect(
                    to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
                    credentials: .oauth2(username: "me@gmail.com", accessToken: "expired-token-xyz")
                )
            }
            #expect(error == .authenticationFailed("Invalid credentials (Failure)"))
            #expect(!String(describing: error).contains("expired-token-xyz"))
            #expect(server.receivedCommands.last == "<continuation>")
        }
    }

    @Test func credentialsDescriptionNeverContainsSecrets() {
        let password = IMAPCredentials.password(username: "u", password: "p4ssw0rd")
        let token = IMAPCredentials.oauth2(username: "u", accessToken: "ya29.secret")
        #expect(!String(describing: password).contains("p4ssw0rd"))
        #expect(!String(describing: token).contains("ya29.secret"))
    }

    @Test func publicServerInitializerAlwaysUsesTLS() {
        let server = IMAPServer(host: "imap.mail.yahoo.co.jp")
        #expect(server.port == 993)
        #expect(server.security == .tls)
    }
}
