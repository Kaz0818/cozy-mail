import Foundation
import NIOCore
import Testing
@testable import MailCore

/// 偽サーバーの台本。`capabilities` は EHLO の返事に並べる機能。
@Sendable private func script(
    capabilities: [String] = ["AUTH PLAIN LOGIN XOAUTH2", "8BITMIME"],
    password: String = "app-password",
    rejecting rejected: String? = nil
) -> FakeSMTPServer.Responder {
    let loginStep = LockedStep()
    return { command in
        let upper = command.uppercased()
        if upper.hasPrefix("EHLO") {
            return ["250-fake.example.com"] + capabilities.dropLast().map { "250-\($0)" } + capabilities.suffix(1).map { "250 \($0)" }
        }
        if upper.hasPrefix("AUTH PLAIN ") {
            let token = String(command.dropFirst("AUTH PLAIN ".count))
            let decoded = Data(base64Encoded: token).map { String(decoding: $0, as: UTF8.self) }
            return decoded == "\u{0}taro@example.com\u{0}\(password)" ? ["235 2.7.0 Accepted"] : ["535 5.7.8 Bad credentials"]
        }
        if upper == "AUTH LOGIN" {
            loginStep.set(1)
            return ["334 VXNlcm5hbWU6"]
        }
        let step = loginStep.value
        if step == 1 {
            loginStep.set(2)
            return Data(base64Encoded: command) == Data("taro@example.com".utf8) ? ["334 UGFzc3dvcmQ6"] : ["535 bad user"]
        }
        if step == 2 {
            loginStep.set(0)
            return Data(base64Encoded: command) == Data(password.utf8) ? ["235 Accepted"] : ["535 5.7.8 Bad credentials"]
        }
        if upper.hasPrefix("AUTH XOAUTH2 ") {
            return ["334 eyJzdGF0dXMiOiI0MDAifQ=="]
        }
        if command.isEmpty { return ["535 5.7.8 Invalid token"] }
        if upper.hasPrefix("MAIL FROM:") { return ["250 2.1.0 OK"] }
        if upper.hasPrefix("RCPT TO:") {
            if let rejected, command.contains(rejected) { return ["550 5.1.1 No such user"] }
            return ["250 2.1.5 OK"]
        }
        if upper == "DATA" { return ["354 Go ahead"] }
        if command == "<END OF DATA>" { return ["250 2.0.0 OK queued"] }
        if upper == "RSET" { return ["250 2.0.0 OK"] }
        if upper == "QUIT" { return ["221 2.0.0 Bye"] }
        if upper == "STARTTLS" { return ["220 2.0.0 Ready to start TLS"] }
        return ["502 5.5.1 Unrecognized command"]
    }
}

/// AUTH LOGIN の何番目の行かを覚える (偽サーバーの台本は、別のスレッドから呼ばれる)。
private final class LockedStep: @unchecked Sendable {
    private let lock = NSLock()
    private var step = 0
    var value: Int { lock.withLock { step } }
    func set(_ newValue: Int) { lock.withLock { step = newValue } }
}

private func server(_ fake: FakeSMTPServer, security: SMTPServer.Security = .plaintextForTesting, host: String = "127.0.0.1") -> SMTPServer {
    SMTPServer(host: host, port: fake.port, security: security)
}

private let password = MailCredentials.password(username: "taro@example.com", password: "app-password")

@Suite struct SMTPSessionTests {
    @Test func sendsAMessageWithAuthPlain() async throws {
        let fake = try await FakeSMTPServer(respond: script())
        let session = try await SMTPSession.connect(to: server(fake), credentials: password)
        let message = Data("Subject: test\r\n\r\nhello\r\n".utf8)
        try await session.send(message, from: "taro@example.com", to: ["a@example.org", "b@example.org"])
        await session.quit()
        await fake.shutdown()

        let commands = fake.receivedCommands
        #expect(commands.first == "EHLO [127.0.0.1]")
        #expect(commands.dropFirst().first?.hasPrefix("AUTH PLAIN ") == true)
        #expect(Array(commands.dropFirst(2)) == [
            "MAIL FROM:<taro@example.com>",
            "RCPT TO:<a@example.org>",
            "RCPT TO:<b@example.org>",
            "DATA",
            "QUIT",
        ])
        #expect(fake.messages == ["Subject: test\r\n\r\nhello"])
    }

    @Test func usesAuthLoginWhenPlainIsNotOffered() async throws {
        let fake = try await FakeSMTPServer(respond: script(capabilities: ["AUTH LOGIN"]))
        let session = try await SMTPSession.connect(to: server(fake), credentials: password)
        await session.quit()
        await fake.shutdown()
        #expect(fake.receivedCommands.contains("AUTH LOGIN"))
        #expect(!fake.receivedCommands.contains { $0.hasPrefix("AUTH PLAIN") })
    }

    @Test func wrongPasswordFailsBeforeSendingAnything() async throws {
        let fake = try await FakeSMTPServer(respond: script(password: "the-real-one"))
        await #expect(throws: SMTPError.authenticationFailed("5.7.8 Bad credentials")) {
            _ = try await SMTPSession.connect(to: server(fake), credentials: password)
        }
        await fake.shutdown()
        #expect(!fake.receivedCommands.contains { $0.hasPrefix("MAIL") })
    }

    /// XOAUTH2 の失敗: サーバーは理由を 334 で返す。空の行を送ると 535 が来る。
    @Test func failedOAuthAnswersTheChallengeAndReportsTheFailure() async throws {
        let fake = try await FakeSMTPServer(respond: script())
        await #expect(throws: SMTPError.authenticationFailed("5.7.8 Invalid token")) {
            _ = try await SMTPSession.connect(to: server(fake), credentials: .oauth2(username: "taro@gmail.com", accessToken: "expired"))
        }
        await fake.shutdown()
        #expect(fake.receivedCommands.last == "")
    }

    @Test func serverWithoutUsableLoginIsReported() async throws {
        let fake = try await FakeSMTPServer(respond: script(capabilities: ["AUTH CRAM-MD5"]))
        await #expect(throws: SMTPError.authenticationUnsupported) {
            _ = try await SMTPSession.connect(to: server(fake), credentials: password)
        }
        await fake.shutdown()
    }

    /// 宛先が 1 つでも断られたら、本文は送らない (一部の人にだけ届くのを防ぐ)。
    @Test func rejectedRecipientStopsTheWholeSend() async throws {
        let fake = try await FakeSMTPServer(respond: script(rejecting: "nobody@example.org"))
        let session = try await SMTPSession.connect(to: server(fake), credentials: password)
        await #expect(throws: SMTPError.recipientRejected(address: "nobody@example.org", reason: "5.1.1 No such user")) {
            try await session.send(Data("x\r\n".utf8), from: "taro@example.com", to: ["a@example.org", "nobody@example.org"])
        }
        await session.quit()
        await fake.shutdown()
        #expect(fake.receivedCommands.contains("RSET"))
        #expect(!fake.receivedCommands.contains("DATA"))
        #expect(fake.messages.isEmpty)
    }

    /// 「.」で始まる行は「..」にして送る。そうしないと「.」だけの行で本文が途中で終わってしまう。
    @Test func linesStartingWithADotAreEscaped() async throws {
        let fake = try await FakeSMTPServer(respond: script())
        let session = try await SMTPSession.connect(to: server(fake), credentials: password)
        try await session.send(Data("Subject: x\r\n\r\n.\r\n.hidden\r\nend".utf8), from: "taro@example.com", to: ["a@example.org"])
        await session.quit()
        await fake.shutdown()
        #expect(fake.messages == ["Subject: x\r\n\r\n..\r\n..hidden\r\nend"])
    }

    @Test func dotStuffingNormalizesLineEndings() {
        let stuffed = SMTPSession.dotStuffed(Data(".a\nb\r\n.c".utf8))
        #expect(String(decoding: stuffed, as: UTF8.self) == "..a\r\nb\r\n..c\r\n.\r\n")
    }

    /// STARTTLS が必要な接続で、サーバーが対応していなければ、ログインせずにやめる (暗号化なしで送らない)。
    @Test func refusesToContinueWithoutEncryption() async throws {
        let fake = try await FakeSMTPServer(respond: script())
        await #expect(throws: SMTPError.encryptionUnavailable) {
            _ = try await SMTPSession.connect(to: server(fake, security: .startTLS), credentials: password)
        }
        await fake.shutdown()
        #expect(fake.receivedCommands == ["EHLO [127.0.0.1]"])
    }

    /// STARTTLS のあとは TLS で話す。偽サーバーは TLS を話せないので失敗するが、平文のままログインはしない。
    @Test func switchesToTLSBeforeLoggingIn() async throws {
        let fake = try await FakeSMTPServer(respond: { command in
            if command.uppercased() == "STARTTLS" { return ["220 Ready to start TLS"] }
            if command.hasPrefix("EHLO") { return ["250-fake", "250-STARTTLS", "250 AUTH PLAIN"] }
            // TLS のあいさつ (読めない行) が来たら切る
            return []
        })
        await #expect(throws: SMTPError.self) {
            _ = try await SMTPSession.connect(to: server(fake, security: .startTLS, host: "localhost"), credentials: password, replyTimeout: .seconds(5))
        }
        await fake.shutdown()
        #expect(Array(fake.receivedCommands.prefix(2)) == ["EHLO [127.0.0.1]", "STARTTLS"])
        #expect(!fake.receivedCommands.contains { $0.hasPrefix("AUTH") })
    }

    @Test func refusedGreetingIsAConnectionFailure() async throws {
        let fake = try await FakeSMTPServer(greeting: "554 5.3.2 Service unavailable", respond: script())
        await #expect(throws: SMTPError.connectionFailed("5.3.2 Service unavailable")) {
            _ = try await SMTPSession.connect(to: server(fake), credentials: password)
        }
        await fake.shutdown()
    }

    @Test func silentServerTimesOut() async throws {
        let fake = try await FakeSMTPServer(respond: { _ in ["<silent>"] })
        await #expect(throws: SMTPError.timedOut) {
            _ = try await SMTPSession.connect(to: server(fake), credentials: password, replyTimeout: .milliseconds(300))
        }
        await fake.shutdown()
    }

    @Test func publicServersAreAlwaysEncrypted() {
        #expect(SMTPServer(host: "smtp.gmail.com", port: 465).security == .tls)
        #expect(SMTPServer(host: "smtp.mail.me.com", port: 587).security == .startTLS)
        #expect(SMTPServer(host: "smtp.example.com", port: 25).security == .startTLS)
    }

    @Test func passwordIsNotPrintedInDescriptions() {
        #expect(!String(describing: password).contains("app-password"))
    }
}
