import Foundation
import Testing
@testable import MailCore

/// 同期 (T10) に使う命令: 日付での検索、UID を指定した見出しの取得、フラグの取り直し、Gmail のラベル。
@Suite(.serialized) struct IMAPSyncCommandsTests {
    private static func header(_ subject: String) -> String {
        "Subject: \(subject)\r\nFrom: a@example.com\r\n\r\n"
    }

    /// Gmail の実際の応答と同じ形の台本。UID 101・102・105 の 3 通がある。
    @Sendable private static func gmailScript(_ command: String) -> [String] {
        let upper = command.uppercased()
        if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
        if upper.hasPrefix("EXAMINE") {
            return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "* OK [UIDNEXT 106] ok", "TAG OK [READ-ONLY] done"]
        }
        if upper.hasPrefix("UID SEARCH") { return ["* SEARCH 101 102 105", "TAG OK SEARCH completed"] }
        if upper.hasPrefix("UID FETCH"), upper.contains("BODY.PEEK[HEADER]") {
            let first = header("one")
            let second = header("two")
            return [
                "* 1 FETCH (X-GM-THRID 9001 X-GM-MSGID 5001 X-GM-LABELS (\\Inbox \\Important \"Work\") UID 101 "
                    + "FLAGS (\\Seen) RFC822.SIZE 100 BODY[HEADER] {\(first.utf8.count)}\r\n\(first))",
                "* 2 FETCH (X-GM-THRID 9002 X-GM-MSGID 5002 X-GM-LABELS (\\Sent) UID 102 "
                    + "FLAGS () RFC822.SIZE 200 BODY[HEADER] {\(second.utf8.count)}\r\n\(second))",
                "TAG OK FETCH completed",
            ]
        }
        if upper.hasPrefix("UID FETCH") {
            // フラグだけ: 102 は消えたので返らない
            return [
                "* 1 FETCH (X-GM-MSGID 5001 X-GM-LABELS (\\Inbox) UID 101 FLAGS (\\Seen \\Flagged))",
                "* 3 FETCH (X-GM-MSGID 5005 X-GM-LABELS () UID 105 FLAGS ())",
                "TAG OK FETCH completed",
            ]
        }
        if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
        return ["TAG BAD unknown"]
    }

    private func withSession(
        _ body: (IMAPSession, FakeIMAPServer) async throws -> Void
    ) async throws {
        let server = try await FakeIMAPServer(respond: Self.gmailScript)
        let session = try await IMAPSession.connect(
            to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
            credentials: .password(username: "me@gmail.com", password: "app-password")
        )
        do {
            try await body(session, server)
        } catch {
            await session.logout()
            await server.shutdown()
            throw error
        }
        await session.logout()
        await server.shutdown()
    }

    @Test func searchesUIDsSinceADate() async throws {
        try await withSession { session, server in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            let since = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!

            let uids = try await session.searchUIDs(in: "[Gmail]/All Mail", since: since, calendar: calendar)

            #expect(uids == [101, 102, 105])
            #expect(server.receivedCommands.contains { $0.hasPrefix("EXAMINE") && $0.contains("[Gmail]/All Mail") })
            #expect(server.receivedCommands.contains { $0.hasPrefix("UID SEARCH SINCE") && $0.contains("14-Oct-2026") })
        }
    }

    @Test func fetchesHeadersByUIDWithGmailAttributes() async throws {
        try await withSession { session, server in
            let headers = try await session.fetchHeaders(
                in: "[Gmail]/All Mail", uids: [105, 101, 102], includeGmailAttributes: true
            )

            #expect(headers.map(\.uid) == [101, 102])
            #expect(headers.map(\.gmailMessageID) == [5001, 5002])
            #expect(headers.map(\.gmailThreadID) == [9001, 9002])
            #expect(headers.map(\.gmailLabels) == [["\\Inbox", "\\Important", "Work"], ["\\Sent"]])
            #expect(headers.map(\.isSeen) == [true, false])
            #expect(try MIMEParser.parse(headers[0].headerData).subject == "one")
            let fetch = try #require(server.receivedCommands.first { $0.hasPrefix("UID FETCH") })
            #expect(fetch.hasPrefix("UID FETCH 101:102,105 "))
            #expect(fetch.contains("X-GM-MSGID") && fetch.contains("X-GM-LABELS") && fetch.contains("BODY.PEEK[HEADER]"))
        }
    }

    @Test func fetchesHeadersWithoutGmailAttributesForOtherProviders() async throws {
        try await withSession { session, server in
            _ = try await session.fetchHeaders(in: "INBOX", uids: [101], includeGmailAttributes: false)
            let fetch = try #require(server.receivedCommands.first { $0.hasPrefix("UID FETCH") })
            #expect(!fetch.contains("X-GM-"))
        }
    }

    @Test func fetchesNewHeadersFromAUIDOnwards() async throws {
        try await withSession { session, server in
            _ = try await session.fetchHeaders(in: "INBOX", fromUID: 106, includeGmailAttributes: false)
            #expect(server.receivedCommands.contains { $0.hasPrefix("UID FETCH 106:* ") })
        }
    }

    @Test func refreshesFlagsAndLabelsWithoutHeaders() async throws {
        try await withSession { session, server in
            let flags = try await session.fetchFlags(in: "[Gmail]/All Mail", uids: 101...105, includeGmailAttributes: true)

            #expect(flags.map(\.uid) == [101, 105])
            #expect(flags[0].flags == ["\\Seen", "\\Flagged"])
            #expect(flags[0].gmailLabels == ["\\Inbox"])
            #expect(flags.allSatisfy { $0.headerData.isEmpty })
            let fetch = try #require(server.receivedCommands.first { $0.hasPrefix("UID FETCH") })
            #expect(fetch.hasPrefix("UID FETCH 101:105 "))
            #expect(!fetch.contains("BODY"))
        }
    }

    @Test func examinesEachMailboxOnlyOnceInARow() async throws {
        try await withSession { session, server in
            _ = try await session.fetchFlags(in: "INBOX", uids: 1...5, includeGmailAttributes: false)
            _ = try await session.fetchHeaders(in: "INBOX", fromUID: 6, includeGmailAttributes: false)
            #expect(server.receivedCommands.filter { $0.hasPrefix("EXAMINE") }.count == 1)
        }
    }

    @Test func emptyUIDListFetchesNothing() async throws {
        try await withSession { session, server in
            let headers = try await session.fetchHeaders(in: "INBOX", uids: [], includeGmailAttributes: false)
            #expect(headers.isEmpty)
            #expect(!server.receivedCommands.contains { $0.hasPrefix("UID FETCH") })
        }
    }
}
