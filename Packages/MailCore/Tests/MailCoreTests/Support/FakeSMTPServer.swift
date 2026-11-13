import Foundation
import NIOCore
import NIOPosix

/// テスト用の偽 SMTP サーバー。127.0.0.1 の空いているポートで、暗号化なしで待ち受ける。
/// 受け取った命令 (1 行) ごとに `respond` を呼び、返した行をそのまま送る。
/// `DATA` のあとの本文は、「.」だけの行までをまとめて `messages` に入れ、`respond("<END OF DATA>")` を呼ぶ。
/// `respond` が空の配列を返したら、何も返さずに接続を切る。`["<silent>"]` なら、何も返さずに待つ。
final class FakeSMTPServer: Sendable {
    typealias Responder = @Sendable (_ command: String) -> [String]

    let port: Int
    private let channel: Channel
    private let log: CommandLog
    private let received: CommandLog

    /// サーバーが受け取った命令の行。
    var receivedCommands: [String] { log.lines }
    /// `DATA` で受け取った本文 (届いたままの形。「.」の足し算は戻していない)。
    var messages: [String] { received.lines }

    init(greeting: String = "220 fake.example.com ESMTP ready", respond: @escaping Responder) async throws {
        let log = CommandLog()
        let received = CommandLog()
        self.log = log
        self.received = received
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        FakeSMTPHandler(greeting: greeting, respond: respond, log: log, received: received)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        port = channel.localAddress?.port ?? 0
    }

    func shutdown() async {
        try? await channel.close()
    }
}

private final class FakeSMTPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let greeting: String
    private let respond: FakeSMTPServer.Responder
    private let log: CommandLog
    private let received: CommandLog
    private var pending = ""
    private var dataLines: [String]?

    init(greeting: String, respond: @escaping FakeSMTPServer.Responder, log: CommandLog, received: CommandLog) {
        self.greeting = greeting
        self.respond = respond
        self.log = log
        self.received = received
    }

    func channelActive(context: ChannelHandlerContext) {
        send([greeting], context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        while let newline = pending.range(of: "\r\n") {
            let line = String(pending[..<newline.lowerBound])
            pending = String(pending[newline.upperBound...])
            handle(line, context: context)
        }
    }

    private func handle(_ line: String, context: ChannelHandlerContext) {
        if var lines = dataLines {
            if line == "." {
                dataLines = nil
                received.append(lines.joined(separator: "\r\n"))
                reply(to: "<END OF DATA>", context: context)
            } else {
                lines.append(line)
                dataLines = lines
            }
            return
        }
        log.append(line)
        reply(to: line, context: context)
        if line.uppercased() == "DATA", lastReplyStartedData {
            dataLines = []
        }
    }

    private var lastReplyStartedData = false

    private func reply(to command: String, context: ChannelHandlerContext) {
        let replies = respond(command)
        lastReplyStartedData = replies.last?.hasPrefix("354") ?? false
        guard !replies.isEmpty else {
            context.close(promise: nil)
            return
        }
        if replies != ["<silent>"] { send(replies, context: context) }
        if command.uppercased() == "QUIT" {
            context.close(promise: nil)
        }
    }

    private func send(_ lines: [String], context: ChannelHandlerContext) {
        let buffer = context.channel.allocator.buffer(string: lines.map { $0 + "\r\n" }.joined())
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
