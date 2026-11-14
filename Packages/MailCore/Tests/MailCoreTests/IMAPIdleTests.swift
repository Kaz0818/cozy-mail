import Foundation
import Testing
@testable import MailCore

/// IMAP の IDLE (T20a): サーバーが「フォルダが変わった」と知らせてくれるのを待つ。
@Suite(.serialized) struct IMAPIdleTests {
    /// `onIdle` で、IDLE を受け取ったときにサーバーが返す行を変えられる台本。
    private static func script(capabilities: String = "IMAP4rev1 IDLE", onIdle: [String]) -> FakeIMAPServer.Responder {
        { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("CAPABILITY") { return ["* CAPABILITY \(capabilities)", "TAG OK done"] }
            if upper.hasPrefix("EXAMINE") {
                return ["* 3 EXISTS", "* OK [UIDVALIDITY 7] ok", "TAG OK [READ-ONLY] EXAMINE completed"]
            }
            if upper == "IDLE" { return onIdle }
            if upper == "<CONTINUATION>DONE" { return ["TAG OK IDLE terminated"] }
            if upper.hasPrefix("NOOP") { return ["TAG OK NOOP completed"] }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
    }

    private func withSession(
        _ script: @escaping FakeIMAPServer.Responder,
        _ body: (IMAPSession, FakeIMAPServer) async throws -> Void
    ) async throws {
        let server = try await FakeIMAPServer(respond: script)
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

    @Test func reportsANewMessage() async throws {
        try await withSession(Self.script(onIdle: ["+ idling", "* 4 EXISTS"])) { session, server in
            let event = try await session.idle(in: "INBOX", timeout: .seconds(5))
            #expect(event == .changed)
            // 知らせを受けたら DONE で IDLE を抜け、次の命令を送れる
            #expect(server.receivedCommands.contains("<continuation>DONE"))
            #expect(server.receivedCommands.filter { $0.uppercased().hasPrefix("EXAMINE") }.count == 1)
            try await session.noop()
        }
    }

    @Test func reportsADeletedMessage() async throws {
        try await withSession(Self.script(onIdle: ["+ idling", "* 2 EXPUNGE"])) { session, _ in
            let event = try await session.idle(in: "INBOX", timeout: .seconds(5))
            #expect(event == .changed)
        }
    }

    @Test func reportsAFlagChange() async throws {
        try await withSession(Self.script(onIdle: ["+ idling", "* 2 FETCH (FLAGS (\\Seen))"])) { session, _ in
            let event = try await session.idle(in: "INBOX", timeout: .seconds(5))
            #expect(event == .changed)
        }
    }

    /// 何も起きなければ、決めた時間で IDLE を抜けて `.timedOut` を返す (25 分ごとに入り直すため)。
    @Test func timesOutWhenNothingHappens() async throws {
        try await withSession(Self.script(onIdle: ["+ idling"])) { session, server in
            let start = ContinuousClock.now
            let event = try await session.idle(in: "INBOX", timeout: .milliseconds(300))
            #expect(event == .timedOut)
            #expect(ContinuousClock.now - start < .seconds(3))
            #expect(server.receivedCommands.contains("<continuation>DONE"))
            try await session.noop()
        }
    }

    /// 待っている作業が止められたら、IDLE を抜けて `.cancelled` を返す。
    @Test func stopsWhenCancelled() async throws {
        try await withSession(Self.script(onIdle: ["+ idling"])) { session, server in
            let task = Task { try await session.idle(in: "INBOX", timeout: .seconds(60)) }
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
            let event = try await task.value
            #expect(event == .cancelled)
            #expect(server.receivedCommands.contains("<continuation>DONE"))
        }
    }

    @Test func knowsWhetherTheServerSupportsIdle() async throws {
        try await withSession(Self.script(onIdle: [])) { session, _ in
            let supported = try await session.supportsIdle()
            #expect(supported)
        }
        try await withSession(Self.script(capabilities: "IMAP4rev1", onIdle: [])) { session, _ in
            let supported = try await session.supportsIdle()
            #expect(supported == false)
        }
    }

    /// サーバーが IDLE を断ったら、エラーにする (見張る側で 1 分ごとの確認に切り替える)。
    @Test func aRefusedIdleThrows() async throws {
        try await withSession(Self.script(onIdle: ["TAG BAD IDLE not supported"])) { session, _ in
            await #expect(throws: IMAPError.self) { try await session.idle(in: "INBOX", timeout: .seconds(5)) }
        }
    }

    @Test func aDroppedConnectionThrows() async throws {
        try await withSession(Self.script(onIdle: ["+ idling", "* BYE server shutting down"])) { session, _ in
            await #expect(throws: IMAPError.self) { try await session.idle(in: "INBOX", timeout: .seconds(5)) }
        }
    }
}
