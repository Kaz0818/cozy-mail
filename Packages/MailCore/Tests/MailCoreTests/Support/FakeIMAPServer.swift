import Foundation
import NIOCore
import NIOPosix

/// テスト用の偽 IMAP サーバー。127.0.0.1 の空いているポートで、暗号化なしで待ち受ける。
/// 受け取った命令 (1 行) ごとに `respond` を呼び、返した行をそのまま送る (`TAG` は命令のタグに置き換える)。
final class FakeIMAPServer: Sendable {
    typealias Responder = @Sendable (_ command: String) -> [String]

    let port: Int
    private let channel: Channel
    private let log: CommandLog

    /// サーバーが受け取った命令の行 (タグを除く)。
    var receivedCommands: [String] {
        log.lines
    }

    init(greeting: String = "* OK [CAPABILITY IMAP4rev1] Fake ready", respond: @escaping Responder) async throws {
        let log = CommandLog()
        self.log = log
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        FakeIMAPHandler(greeting: greeting, respond: respond, log: log)
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

final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.withLock { storage }
    }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}

private final class FakeIMAPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let greeting: String
    private let respond: FakeIMAPServer.Responder
    private let log: CommandLog
    private var pending = ""

    init(greeting: String, respond: @escaping FakeIMAPServer.Responder, log: CommandLog) {
        self.greeting = greeting
        self.respond = respond
        self.log = log
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
        guard let space = line.firstIndex(of: " ") else { return }
        let tag = String(line[..<space])
        let command = String(line[line.index(after: space)...])
        log.append(command)
        let replies = respond(command).map { $0.replacingOccurrences(of: "TAG", with: tag) }
        send(replies, context: context)
        if command.uppercased().hasPrefix("LOGOUT") {
            context.close(promise: nil)
        }
    }

    private func send(_ lines: [String], context: ChannelHandlerContext) {
        guard !lines.isEmpty else { return }
        let buffer = context.channel.allocator.buffer(string: lines.map { $0 + "\r\n" }.joined())
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
