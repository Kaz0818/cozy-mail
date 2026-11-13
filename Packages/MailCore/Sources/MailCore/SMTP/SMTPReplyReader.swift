import NIOCore

/// サーバーから届いたバイト列を、SMTP の返事 (`250-...` が続き `250 ...` で終わる) にまとめる。
/// 状態はすべてチャネルのイベントループ上でだけ触る。
final class SMTPReplyReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var pendingBytes: [UInt8] = []
    private var partialLines: [String] = []
    private var ready: [SMTPReply] = []
    private var waiter: EventLoopPromise<SMTPReply>?
    private var timeout: Scheduled<Void>?
    private var failure: SMTPError?

    /// 次の返事を待つ。`limit` を過ぎたら `timedOut`。
    func nextReply(on eventLoop: EventLoop, limit: TimeAmount) async throws(SMTPError) -> SMTPReply {
        let future = eventLoop.flatSubmit { () -> EventLoopFuture<SMTPReply> in
            if !self.ready.isEmpty { return eventLoop.makeSucceededFuture(self.ready.removeFirst()) }
            if let failure = self.failure { return eventLoop.makeFailedFuture(failure) }
            let promise = eventLoop.makePromise(of: SMTPReply.self)
            self.waiter = promise
            self.timeout = eventLoop.scheduleTask(in: limit) {
                self.waiter = nil
                promise.fail(SMTPError.timedOut)
            }
            return promise.futureResult
        }
        do {
            return try await future.get()
        } catch let error as SMTPError {
            throw error
        } catch {
            throw .connectionClosed
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pendingBytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        while let newline = pendingBytes.firstIndex(of: UInt8(ascii: "\n")) {
            var lineBytes = pendingBytes[..<newline]
            if lineBytes.last == UInt8(ascii: "\r") { lineBytes = lineBytes.dropLast() }
            pendingBytes.removeSubrange(...newline)
            handle(line: String(decoding: lineBytes, as: UTF8.self), context: context)
        }
    }

    private func handle(line: String, context: ChannelHandlerContext) {
        let characters = Array(line)
        guard characters.count >= 3, let code = Int(String(characters[0..<3])) else {
            fail(.unexpectedResponse(line), context: context)
            return
        }
        let separator = characters.count > 3 ? characters[3] : " "
        let text = characters.count > 4 ? String(characters[4...]) : ""
        partialLines.append(text)
        guard separator != "-" else { return }
        deliver(SMTPReply(code: code, lines: partialLines))
        partialLines = []
    }

    private func deliver(_ reply: SMTPReply) {
        if let waiter {
            self.waiter = nil
            timeout?.cancel()
            waiter.succeed(reply)
        } else {
            ready.append(reply)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(.connectionClosed, context: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(.connectionFailed(String(describing: error)), context: context)
    }

    private func fail(_ error: SMTPError, context: ChannelHandlerContext?) {
        if failure == nil { failure = error }
        timeout?.cancel()
        waiter?.fail(error)
        waiter = nil
        context?.close(promise: nil)
    }
}
