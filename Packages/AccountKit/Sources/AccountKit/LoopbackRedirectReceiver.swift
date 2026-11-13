import Foundation
import NIOCore
import NIOPosix

/// ブラウザでのログインの結果を、127.0.0.1 の空いているポートで受け取る (RFC 8252 7.3)。
/// 認可コードつきのリクエストを 1 回受け取ったら閉じる。
public final class LoopbackRedirectReceiver: Sendable {
    public let port: Int
    private let serverChannel: Channel
    private let result: EventLoopPromise<URL>

    /// Google に渡すリダイレクト先。
    public var redirectURI: String {
        "http://127.0.0.1:\(port)"
    }

    private init(port: Int, serverChannel: Channel, result: EventLoopPromise<URL>) {
        self.port = port
        self.serverChannel = serverChannel
        self.result = result
    }

    public static func start() async throws -> LoopbackRedirectReceiver {
        let group = MultiThreadedEventLoopGroup.singleton
        let result = group.next().makePromise(of: URL.self)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RedirectRequestHandler(result: result))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let receiver = LoopbackRedirectReceiver(port: channel.localAddress?.port ?? 0, serverChannel: channel, result: result)
        result.futureResult.whenComplete { _ in channel.close(promise: nil) }
        return receiver
    }

    /// ブラウザが戻ってくるまで待つ。戻ってきた URL (`http://127.0.0.1:port/?code=...&state=...`) を返す。
    public func waitForRedirect() async throws -> URL {
        try await result.futureResult.get()
    }

    /// 待つのをやめる (ログイン画面を閉じられたときなど)。
    public func cancel() {
        result.fail(CancellationError())
    }
}

private final class RedirectRequestHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let result: EventLoopPromise<URL>
    private var received = ""

    init(result: EventLoopPromise<URL>) {
        self.result = result
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readString(length: buffer.readableBytes) ?? ""
        guard received.contains("\r\n\r\n") || received.contains("\n\n"),
              let requestLine = received.split(whereSeparator: \.isNewline).first else { return }

        // 例: GET /?state=...&code=... HTTP/1.1
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : "/"
        let localAddress = "http://127.0.0.1:\(context.channel.localAddress?.port ?? 0)"
        if target.hasPrefix("/?"), let url = URL(string: localAddress + target) {
            respond(context: context, status: "200 OK", body: Self.donePage)
            result.succeed(url)
        } else {
            respond(context: context, status: "404 Not Found", body: "")
        }
    }

    private func respond(context: ChannelHandlerContext, status: String, body: String) {
        let bodyBytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        var buffer = context.channel.allocator.buffer(capacity: head.utf8.count + bodyBytes.count)
        buffer.writeString(head)
        buffer.writeBytes(bodyBytes)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in context.close(promise: nil) }
    }

    private static let donePage = """
    <!doctype html><html lang="ja"><head><meta charset="utf-8"><title>Cozy Mail</title>
    <style>body{font-family:-apple-system,sans-serif;background:#E6F6F4;color:#0F1F1E;display:grid;place-items:center;height:100vh;margin:0}
    div{padding:32px 40px;border-radius:24px;background:rgba(255,255,255,.7);text-align:center}</style></head>
    <body><div><h1>Cozy Mail</h1><p>ログインが終わりました。このタブを閉じて、Cozy Mail に戻ってください。</p></div></body></html>
    """
}
