import Foundation
import Testing
@testable import MailCore

/// 送ったメールを「送信済み」に入れる `APPEND` (T18)。
@Suite struct IMAPAppendTests {
    /// サーバーの「+」を待ってから本文を送り、`OK` で終わる。
    /// (偽サーバーは 1 行ずつ読むので、本文は空白のない 2 行にしている)
    @Test func appendWaitsForTheContinuationAndSendsTheMessage() async throws {
        let server = try await FakeIMAPServer { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("APPEND") { return ["+ Ready for literal data"] }
            if command == "<continuation>Line1" { return [] }
            if command == "<continuation>Line2" { return ["TAG OK [APPENDUID 7 42] APPEND completed"] }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
        let session = try await IMAPSession.connect(
            to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
            credentials: .password(username: "me", password: "pw")
        )
        try await session.append(Data("Line1\r\nLine2".utf8), to: "Sent")
        await session.logout()
        await server.shutdown()

        let commands = server.receivedCommands
        let append = try #require(commands.first { $0.uppercased().hasPrefix("APPEND") })
        #expect(append.contains("Sent"))
        #expect(append.contains("(\\Seen)"))
        #expect(append.contains("{12}"))
        #expect(commands.contains("<continuation>Line1"))
        #expect(commands.contains("<continuation>Line2"))
    }

    /// 送る先のフォルダがないなど、サーバーが断ったら失敗を返す。
    @Test func refusedAppendIsReported() async throws {
        let server = try await FakeIMAPServer { command in
            let upper = command.uppercased()
            if upper.hasPrefix("LOGIN") { return ["TAG OK Logged in"] }
            if upper.hasPrefix("APPEND") { return ["TAG NO [TRYCREATE] No such mailbox"] }
            if upper.hasPrefix("LOGOUT") { return ["* BYE", "TAG OK bye"] }
            return ["TAG BAD unknown"]
        }
        let session = try await IMAPSession.connect(
            to: IMAPServer(host: "127.0.0.1", port: server.port, security: .plaintextForTesting),
            credentials: .password(username: "me", password: "pw")
        )
        // swift-nio-imap は「+」の前に届いた NO を想定外の返事として扱い、接続を閉じる。失敗として返れば十分
        await #expect(throws: IMAPError.self) {
            try await session.append(Data("Line1\r\nLine2".utf8), to: "Missing")
        }
        // 閉じたあとの命令も、止まったり落ちたりせずに失敗する
        await #expect(throws: IMAPError.self) {
            _ = try await session.listMailboxes()
        }
        await session.logout()
        await server.shutdown()
    }
}
