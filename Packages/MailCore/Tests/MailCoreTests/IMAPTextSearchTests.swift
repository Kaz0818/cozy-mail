import Foundation
import Testing
@testable import MailCore

/// サーバー側の検索 (T27): 件名・差出人・本文のどこかに言葉を含むメールを、サーバーで探す (`UID SEARCH TEXT`)。
@Suite(.serialized) struct IMAPTextSearchTests {
    /// 日本語は「リテラル」(`{バイト数}` のあとに中身) で送られるので、`+` (続けてください) を返して中身を受け取る。
    private static func script(searchResult: String) -> FakeIMAPServer.Responder {
        { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("EXAMINE") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "TAG OK [READ-ONLY] EXAMINE completed"]
            }
            if command.hasSuffix("}") { return ["+ go ahead"] }
            if upper.hasPrefix("UID SEARCH") || upper.hasPrefix("<CONTINUATION>") {
                return ["* SEARCH \(searchResult)", "TAG OK SEARCH completed"]
            }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
    }

    private func withSession(
        searchResult: String = "3 12 40",
        _ body: (IMAPSession, FakeIMAPServer) async throws -> Void
    ) async throws {
        let server = try await FakeIMAPServer(respond: Self.script(searchResult: searchResult))
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

    @Test func searchesTheTextOfMessages() async throws {
        try await withSession { session, server in
            let uids = try await session.searchUIDs(in: "INBOX", text: "invoice")
            #expect(uids == [3, 12, 40])
            #expect(server.receivedCommands.contains { $0.hasPrefix("EXAMINE") })
            let search = try #require(server.receivedCommands.first { $0.uppercased().hasPrefix("UID SEARCH") })
            #expect(search == "UID SEARCH TEXT \"invoice\"" || search == "UID SEARCH TEXT invoice")
        }
    }

    /// 言葉が 2 つ以上なら、どれも含むメール (かつ)。
    @Test func severalWordsMustAllMatch() async throws {
        try await withSession { session, server in
            _ = try await session.searchUIDs(in: "INBOX", text: "  project   plan ")
            let search = try #require(server.receivedCommands.first { $0.uppercased().hasPrefix("UID SEARCH") })
            #expect(search.uppercased().contains("TEXT \"PROJECT\"") || search.uppercased().contains("TEXT PROJECT"))
            #expect(search.uppercased().contains("TEXT \"PLAN\"") || search.uppercased().contains("TEXT PLAN"))
            #expect(!search.uppercased().contains(" OR "))
        }
    }

    /// 日本語は UTF-8 で送ると伝える (`CHARSET UTF-8`)。
    @Test func japaneseIsSentAsUTF8() async throws {
        try await withSession { session, server in
            let uids = try await session.searchUIDs(in: "INBOX", text: "請求書")
            #expect(uids == [3, 12, 40])
            let search = try #require(server.receivedCommands.first { $0.uppercased().hasPrefix("UID SEARCH") })
            #expect(search.uppercased().hasPrefix("UID SEARCH CHARSET UTF-8 TEXT {9}"))
            #expect(server.receivedCommands.contains("<continuation>請求書"))
        }
    }

    @Test func nothingFoundIsAnEmptyList() async throws {
        try await withSession(searchResult: "") { session, _ in
            let uids = try await session.searchUIDs(in: "INBOX", text: "nothing")
            #expect(uids.isEmpty)
        }
    }

    /// 空白だけなら、サーバーに聞かない。
    @Test func blankTextSendsNothing() async throws {
        try await withSession { session, server in
            let uids = try await session.searchUIDs(in: "INBOX", text: "   ")
            #expect(uids.isEmpty)
            #expect(!server.receivedCommands.contains { $0.uppercased().hasPrefix("UID SEARCH") })
        }
    }
}
