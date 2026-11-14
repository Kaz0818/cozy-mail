import Foundation
import Testing
@testable import MailCore

/// サーバーの下書き (T23b) に使う命令: 見出しの印で探す、指定したメールだけを消す。
/// 消すのは UIDPLUS の `UID EXPUNGE` だけ。ただの `EXPUNGE` は、フォルダ内のほかの「削除の印」のメールまで消すので使わない。
@Suite(.serialized) struct IMAPDraftCommandsTests {
    private static func script(capabilities: String, searchResult: String) -> FakeIMAPServer.Responder {
        { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("CAPABILITY") { return ["* CAPABILITY \(capabilities)", "TAG OK done"] }
            if upper.hasPrefix("SELECT") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "TAG OK [READ-WRITE] SELECT completed"]
            }
            if upper.hasPrefix("EXAMINE") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "TAG OK [READ-ONLY] EXAMINE completed"]
            }
            if upper.hasPrefix("UID SEARCH") { return ["* SEARCH \(searchResult)", "TAG OK SEARCH completed"] }
            if upper.hasPrefix("UID STORE") || upper.hasPrefix("UID EXPUNGE") { return ["TAG OK done"] }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
    }

    private func withSession(
        capabilities: String = "IMAP4rev1 UIDPLUS",
        searchResult: String = "5 9",
        _ body: (IMAPSession, FakeIMAPServer) async throws -> Void
    ) async throws {
        let server = try await FakeIMAPServer(respond: Self.script(capabilities: capabilities, searchResult: searchResult))
        let session = try await IMAPSession.connect(
            to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
            credentials: .password(username: "me", password: "pw")
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

    private func commands(_ server: FakeIMAPServer, _ prefix: String) -> [String] {
        server.receivedCommands.filter { $0.uppercased().hasPrefix(prefix) }
    }

    @Test func searchesByAHeader() async throws {
        try await withSession { session, server in
            let uids = try await session.searchUIDs(in: "Drafts", header: "X-Cozy-Mail-Draft", containing: "abc-123")
            #expect(uids == [5, 9])
            let search = try #require(commands(server, "UID SEARCH").first)
            #expect(search.uppercased().contains("HEADER"))
            #expect(search.contains("X-Cozy-Mail-Draft"))
            #expect(search.contains("abc-123"))
        }
    }

    @Test func nothingFoundIsAnEmptyList() async throws {
        try await withSession(searchResult: "") { session, _ in
            let uids = try await session.searchUIDs(in: "Drafts", header: "X-Cozy-Mail-Draft", containing: "abc")
            #expect(uids.isEmpty)
        }
    }

    /// 指定したメールに「削除の印」を付け、そのメールだけを `UID EXPUNGE` で消す。
    @Test func deletesOnlyTheGivenMessages() async throws {
        try await withSession { session, server in
            try await session.deleteMessages(uids: [9, 5], in: "Drafts")
            #expect(commands(server, "SELECT").count == 1)
            let store = try #require(commands(server, "UID STORE").first)
            #expect(store.hasPrefix("UID STORE 5,9 "))
            #expect(store.contains("+FLAGS.SILENT") && store.contains("\\Deleted"))
            #expect(commands(server, "UID EXPUNGE").first?.hasPrefix("UID EXPUNGE 5,9") == true)
            #expect(!server.receivedCommands.contains { $0.uppercased() == "EXPUNGE" })
        }
    }

    /// UIDPLUS がないサーバーでは、印も付けずに断る (ほかのメールを消すおそれのある EXPUNGE は使わない)。
    @Test func withoutUIDPlusNothingIsTouched() async throws {
        try await withSession(capabilities: "IMAP4rev1") { session, server in
            await #expect(throws: IMAPError.unsupported("UIDPLUS")) {
                try await session.deleteMessages(uids: [5], in: "Drafts")
            }
            #expect(commands(server, "UID STORE").isEmpty)
            #expect(commands(server, "UID EXPUNGE").isEmpty)
            #expect(!server.receivedCommands.contains { $0.uppercased() == "EXPUNGE" })
        }
    }

    @Test func anEmptyListSendsNothing() async throws {
        try await withSession { session, server in
            try await session.deleteMessages(uids: [], in: "Drafts")
            #expect(commands(server, "UID").isEmpty)
            #expect(commands(server, "SELECT").isEmpty)
        }
    }

    @Test func supportsUIDPlusReportsTheCapability() async throws {
        try await withSession { session, _ in
            let supported = try await session.supportsUIDPlus()
            #expect(supported)
        }
        try await withSession(capabilities: "IMAP4rev1") { session, _ in
            let supported = try await session.supportsUIDPlus()
            #expect(!supported)
        }
    }
}
