import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// 1 つのメールアカウントの送信用 (SMTP) の接続。命令は 1 つずつ順に送る。
///
/// - 暗号化なしでは送らない (ポート 465 は最初から TLS、それ以外は STARTTLS が必須)。
/// - ログインは AUTH PLAIN か AUTH LOGIN (アプリパスワード)、または XOAUTH2。
public actor SMTPSession {
    private let channel: Channel
    private let reader: SMTPReplyReader
    private let replyTimeout: TimeAmount
    /// `EHLO` の返事にあった機能 (大文字、例: `AUTH PLAIN LOGIN`, `STARTTLS`)。
    private var capabilities: [String] = []

    private init(channel: Channel, reader: SMTPReplyReader, replyTimeout: TimeAmount) {
        self.channel = channel
        self.reader = reader
        self.replyTimeout = replyTimeout
    }

    // MARK: - 接続とログイン

    /// 接続してログインする。
    /// - Parameter clientName: `EHLO` で名乗る名前。Mac の名前を外に出さないよう、既定はアドレスの形 (`[127.0.0.1]`)。
    public static func connect(
        to server: SMTPServer,
        credentials: MailCredentials,
        clientName: String = "[127.0.0.1]",
        replyTimeout: TimeAmount = .seconds(60)
    ) async throws(SMTPError) -> SMTPSession {
        let reader = SMTPReplyReader()
        let channel: Channel
        do {
            let sslContext = try makeSSLContext()
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(20))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if server.security == .tls {
                            try pipeline.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: server.host))
                        }
                        try pipeline.addHandler(reader)
                    }
                }
                .connect(host: server.host, port: server.port)
                .get()
        } catch {
            throw .connectionFailed(String(describing: error))
        }

        let session = SMTPSession(channel: channel, reader: reader, replyTimeout: replyTimeout)
        do {
            try await session.start(server: server, clientName: clientName)
            try await session.authenticate(credentials)
        } catch {
            try? await channel.close()
            throw error
        }
        return session
    }

    private static func makeSSLContext() throws -> NIOSSLContext {
        // 既定の設定: OS の証明書で、サーバーの証明書と名前を確かめる
        try NIOSSLContext(configuration: .makeClientConfiguration())
    }

    /// あいさつを受け、EHLO し、必要なら STARTTLS で暗号化に切り替える。
    private func start(server: SMTPServer, clientName: String) async throws(SMTPError) {
        let greeting = try await nextReply()
        guard greeting.code == 220 else { throw .connectionFailed(greeting.text) }
        try await hello(clientName)

        guard server.security == .startTLS else { return }
        guard hasCapability("STARTTLS") else { throw .encryptionUnavailable }
        let reply = try await command("STARTTLS")
        guard reply.code == 220 else { throw .encryptionUnavailable }
        do {
            let context = try Self.makeSSLContext()
            let channel = channel
            let host = server.host
            // TLS の部品は、チャネルのスレッドの上で作って一番手前に入れる
            try await channel.eventLoop.submit {
                let handler = try NIOSSLClientHandler(context: context, serverHostname: host)
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
        } catch {
            throw .connectionFailed(String(describing: error))
        }
        // 暗号化したあとは、機能を聞き直す (RFC 3207)
        try await hello(clientName)
    }

    private func hello(_ clientName: String) async throws(SMTPError) {
        let reply = try await command("EHLO \(clientName)")
        guard reply.code == 250 else { throw .commandFailed(reply.text) }
        capabilities = reply.lines.dropFirst().map { $0.uppercased() }
    }

    private func hasCapability(_ name: String) -> Bool {
        capabilities.contains { $0 == name || $0.hasPrefix(name + " ") }
    }

    /// `AUTH` の行にある方法 (例: `PLAIN`, `LOGIN`, `XOAUTH2`)。
    private var authMechanisms: Set<String> {
        var mechanisms: Set<String> = []
        for line in capabilities where line.hasPrefix("AUTH ") || line.hasPrefix("AUTH=") {
            mechanisms.formUnion(line.dropFirst(5).split(separator: " ").map(String.init))
        }
        return mechanisms
    }

    private func authenticate(_ credentials: MailCredentials) async throws(SMTPError) {
        let mechanisms = authMechanisms
        switch credentials {
        case let .password(username, password):
            if mechanisms.contains("PLAIN") {
                let token = Data("\u{0}\(username)\u{0}\(password)".utf8).base64EncodedString()
                try expectAuthenticated(try await command("AUTH PLAIN \(token)"))
            } else if mechanisms.contains("LOGIN") {
                let first = try await command("AUTH LOGIN")
                guard first.code == 334 else { throw .authenticationFailed(first.text) }
                let second = try await command(Data(username.utf8).base64EncodedString())
                guard second.code == 334 else { throw .authenticationFailed(second.text) }
                try expectAuthenticated(try await command(Data(password.utf8).base64EncodedString()))
            } else {
                throw .authenticationUnsupported
            }
        case let .oauth2(username, accessToken):
            guard mechanisms.contains("XOAUTH2") else { throw .authenticationUnsupported }
            let token = Data(XOAuth2.initialResponse(username: username, accessToken: accessToken).utf8).base64EncodedString()
            var reply = try await command("AUTH XOAUTH2 \(token)")
            if reply.code == 334 {
                // 失敗の理由 (Base64 の JSON) が届いたら、空の行を送ると最終の返事 (535) が来る
                reply = try await command("")
            }
            try expectAuthenticated(reply)
        }
    }

    private func expectAuthenticated(_ reply: SMTPReply) throws(SMTPError) {
        guard reply.code == 235 else { throw .authenticationFailed(reply.text) }
    }

    // MARK: - 送信

    /// 組み立て済みのメール (`MIMEBuilder.build` の結果) を送る。
    /// 宛先が 1 つでも断られたら、何も送らずにやめる (一部の人にだけ届くのを防ぐ)。
    public func send(_ message: Data, from sender: String, to recipients: [String]) async throws(SMTPError) {
        guard !recipients.isEmpty else { throw .noRecipients }
        for address in [sender] + recipients where !Self.isSafeAddress(address) {
            throw .recipientRejected(address: address, reason: "メールアドレスの形が正しくありません")
        }

        let mail = try await command("MAIL FROM:<\(sender)>")
        guard mail.code == 250 else { throw .commandFailed(mail.text) }
        for address in recipients {
            let reply = try await command("RCPT TO:<\(address)>")
            guard reply.code == 250 || reply.code == 251 else {
                _ = try? await command("RSET")
                throw .recipientRejected(address: address, reason: reply.text)
            }
        }
        let data = try await command("DATA")
        guard data.code == 354 else {
            _ = try? await command("RSET")
            throw .commandFailed(data.text)
        }
        // 添付ファイルつきの大きなメールは、送り終えるまで時間がかかるので、待つ時間を長くする
        try await write(Self.dotStuffed(message), limit: .minutes(10))
        let done = try await nextReply()
        guard done.code == 250 else { throw .commandFailed(done.text) }
    }

    /// 送信を終えて接続を閉じる。失敗しても気にしない。
    public func quit() async {
        _ = try? await command("QUIT")
        try? await channel.close()
    }

    /// 本文の「.」で始まる行に「.」を足し (RFC 5321 4.5.2)、最後に「.」だけの行を付ける。改行は CRLF にそろえる。
    static func dotStuffed(_ message: Data) -> Data {
        var output = Data()
        output.reserveCapacity(message.count + 64)
        var atLineStart = true
        var previous: UInt8 = 0
        for byte in message {
            if byte == UInt8(ascii: "\n"), previous != UInt8(ascii: "\r") {
                output.append(UInt8(ascii: "\r"))
            }
            if atLineStart, byte == UInt8(ascii: ".") {
                output.append(UInt8(ascii: "."))
            }
            output.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
            previous = byte
        }
        if !output.isEmpty, !output.ends(with: [UInt8(ascii: "\r"), UInt8(ascii: "\n")]) {
            output.append(contentsOf: [UInt8(ascii: "\r"), UInt8(ascii: "\n")])
        }
        output.append(contentsOf: Array(".\r\n".utf8))
        return output
    }

    /// 命令に入れても安全なアドレスか (改行や `<>` で命令を足されないように)。
    private static func isSafeAddress(_ address: String) -> Bool {
        !address.isEmpty && address.contains("@") && !address.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || " <>".unicodeScalars.contains(scalar)
        }
    }

    // MARK: - やりとり

    private func command(_ line: String) async throws(SMTPError) -> SMTPReply {
        try await write(Data((line + "\r\n").utf8))
        return try await nextReply()
    }

    /// 書き込みが `limit` を過ぎても終わらなければ (TLS の始まりで止まったなど)、接続を閉じて `timedOut` にする。
    private func write(_ data: Data, limit: TimeAmount? = nil) async throws(SMTPError) {
        let channel = channel
        let limit = limit ?? replyTimeout
        let timer = channel.eventLoop.scheduleTask(in: limit) { channel.close(promise: nil) }
        defer { timer.cancel() }
        let started = ContinuousClock.now
        do {
            try await channel.writeAndFlush(channel.allocator.buffer(bytes: data)).get()
        } catch {
            let elapsed = ContinuousClock.now - started
            throw elapsed >= .nanoseconds(limit.nanoseconds) ? .timedOut : .connectionClosed
        }
    }

    private func nextReply() async throws(SMTPError) -> SMTPReply {
        try await reader.nextReply(on: channel.eventLoop, limit: replyTimeout)
    }
}

private extension Data {
    func ends(with suffix: [UInt8]) -> Bool {
        count >= suffix.count && Array(self[(endIndex - suffix.count)...]) == suffix
    }
}
