import Foundation
import Testing
@testable import MailCore

/// 整理の操作 (T15) に使う命令: フラグ・Gmail のラベルの付け外し、フォルダの移動。
@Suite(.serialized) struct IMAPActionCommandsTests {
    /// `capabilities` で、サーバーが MOVE / UIDPLUS に対応しているかを変えられる台本。
    private static func script(capabilities: String) -> FakeIMAPServer.Responder {
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
            if upper.hasPrefix("UID FETCH") { return ["TAG OK FETCH completed"] }
            if upper.hasPrefix("UID STORE") || upper.hasPrefix("UID MOVE") || upper.hasPrefix("UID COPY")
                || upper.hasPrefix("UID EXPUNGE") {
                return ["TAG OK done"]
            }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
    }

    private func withSession(
        capabilities: String = "IMAP4rev1 MOVE UIDPLUS X-GM-EXT-1",
        _ body: (IMAPSession, FakeIMAPServer) async throws -> Void
    ) async throws {
        let server = try await FakeIMAPServer(respond: Self.script(capabilities: capabilities))
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

    @Test func addingAFlagOpensTheFolderReadWrite() async throws {
        try await withSession { session, server in
            try await session.setFlags(["\\Seen"], add: true, in: "INBOX", uids: [101])

            #expect(commands(server, "SELECT").count == 1)
            #expect(commands(server, "EXAMINE").isEmpty)
            let store = try #require(commands(server, "UID STORE").first)
            #expect(store.hasPrefix("UID STORE 101 "))
            #expect(store.contains("+FLAGS.SILENT"))
            #expect(store.contains("\\Seen"))
        }
    }

    @Test func removingAFlag() async throws {
        try await withSession { session, server in
            try await session.setFlags(["\\Flagged"], add: false, in: "INBOX", uids: [101, 102])
            let store = try #require(commands(server, "UID STORE").first)
            #expect(store.hasPrefix("UID STORE 101:102 "))
            #expect(store.contains("-FLAGS.SILENT"))
            #expect(store.contains("\\Flagged"))
        }
    }

    @Test func gmailArchiveRemovesTheInboxLabel() async throws {
        try await withSession { session, server in
            try await session.setGmailLabels(["\\Inbox"], add: false, in: "[Gmail]/All Mail", uids: [5])
            let store = try #require(commands(server, "UID STORE").first)
            #expect(store.hasPrefix("UID STORE 5 "))
            #expect(store.contains("-X-GM-LABELS.SILENT"))
            #expect(store.contains("\\Inbox"))
        }
    }

    @Test func moveUsesUIDMoveWhenTheServerSupportsIt() async throws {
        try await withSession { session, server in
            try await session.move(uids: [101, 103], from: "INBOX", to: "Trash")
            let move = try #require(commands(server, "UID MOVE").first)
            #expect(move.hasPrefix("UID MOVE 101,103 "))
            #expect(move.contains("Trash"))
            #expect(commands(server, "UID COPY").isEmpty)
            #expect(commands(server, "SELECT").count == 1)
        }
    }

    @Test func moveFallsBackToCopyDeleteAndUIDExpunge() async throws {
        try await withSession(capabilities: "IMAP4rev1 UIDPLUS") { session, server in
            try await session.move(uids: [7], from: "INBOX", to: "Archive")

            #expect(commands(server, "UID MOVE").isEmpty)
            let copy = try #require(commands(server, "UID COPY").first)
            #expect(copy.hasPrefix("UID COPY 7 ") && copy.contains("Archive"))
            let store = try #require(commands(server, "UID STORE").first)
            #expect(store.contains("+FLAGS.SILENT") && store.contains("\\Deleted"))
            #expect(commands(server, "UID EXPUNGE").first?.hasPrefix("UID EXPUNGE 7") == true)
        }
    }

    @Test func withoutUIDPlusTheMessageIsOnlyMarkedDeleted() async throws {
        // EXPUNGE だけだと、ほかの「削除の印」のメールまで消してしまうので、使わない
        try await withSession(capabilities: "IMAP4rev1") { session, server in
            try await session.move(uids: [7], from: "INBOX", to: "Archive")
            #expect(commands(server, "UID COPY").count == 1)
            #expect(commands(server, "UID STORE").count == 1)
            #expect(commands(server, "UID EXPUNGE").isEmpty)
            #expect(!server.receivedCommands.contains { $0.uppercased() == "EXPUNGE" })
        }
    }

    @Test func readingAfterWritingDoesNotReopenTheFolder() async throws {
        try await withSession { session, server in
            try await session.setFlags(["\\Seen"], add: true, in: "INBOX", uids: [1])
            _ = try await session.fetchFlags(in: "INBOX", uids: 1...3, includeGmailAttributes: false)
            // 読み書きで開いていれば、読むだけのために開き直さない
            #expect(commands(server, "SELECT").count == 1)
            #expect(commands(server, "EXAMINE").isEmpty)
        }
    }

    @Test func writingAfterReadingReopensReadWrite() async throws {
        try await withSession { session, server in
            _ = try await session.fetchFlags(in: "INBOX", uids: 1...3, includeGmailAttributes: false)
            try await session.setFlags(["\\Seen"], add: true, in: "INBOX", uids: [1])
            #expect(commands(server, "EXAMINE").count == 1)
            #expect(commands(server, "SELECT").count == 1)
        }
    }

    @Test func emptyUIDListSendsNothing() async throws {
        try await withSession { session, server in
            try await session.setFlags(["\\Seen"], add: true, in: "INBOX", uids: [])
            try await session.move(uids: [], from: "INBOX", to: "Trash")
            #expect(commands(server, "UID").isEmpty)
            #expect(commands(server, "SELECT").isEmpty)
        }
    }
}
