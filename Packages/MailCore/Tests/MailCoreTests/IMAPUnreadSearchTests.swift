import Foundation
import Testing
@testable import MailCore

/// 受信トレイの未読をすべて探す (受信トレイをすべて既読にするため): `UID SEARCH UNSEEN`。
@Suite(.serialized) struct IMAPUnreadSearchTests {
    private static func script(searchResult: String) -> FakeIMAPServer.Responder {
        { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("EXAMINE") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "TAG OK [READ-ONLY] EXAMINE completed"]
            }
            if upper.hasPrefix("UID SEARCH") { return ["* SEARCH \(searchResult)", "TAG OK SEARCH completed"] }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
    }

    private func withSession(
        searchResult: String,
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

    @Test func findsUnreadMessagesInOrder() async throws {
        try await withSession(searchResult: "40 3 12") { session, server in
            let uids = try await session.searchUnreadUIDs(in: "INBOX")
            #expect(uids == [3, 12, 40])
            // 読むだけなので EXAMINE (読み取り専用) で開く
            #expect(server.receivedCommands.contains { $0.uppercased().hasPrefix("EXAMINE") })
            let search = try #require(server.receivedCommands.first { $0.uppercased().hasPrefix("UID SEARCH") })
            #expect(search.uppercased() == "UID SEARCH UNSEEN")
        }
    }

    @Test func noUnreadIsAnEmptyList() async throws {
        try await withSession(searchResult: "") { session, _ in
            let uids = try await session.searchUnreadUIDs(in: "INBOX")
            #expect(uids.isEmpty)
        }
    }
}
