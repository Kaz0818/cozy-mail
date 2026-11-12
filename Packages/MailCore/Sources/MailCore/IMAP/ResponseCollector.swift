import NIOCore
import NIOIMAP

/// サーバーからの応答を、送った命令 (タグ) ごとにまとめて返す。
/// 状態はすべてチャネルのイベントループ上でだけ触る。
final class ResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private var greeting: EventLoopPromise<Void>?
    private var greetingReceived = false
    private var current: (tag: String, promise: EventLoopPromise<[Response]>, responses: [Response])?

    /// 接続直後のあいさつ (`* OK ...`) を待つ。
    func waitForGreeting(on eventLoop: EventLoop) async throws(IMAPError) {
        let future = eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            if self.greetingReceived { return eventLoop.makeSucceededVoidFuture() }
            let promise = eventLoop.makePromise(of: Void.self)
            self.greeting = promise
            return promise.futureResult
        }
        do {
            try await future.get()
        } catch let error as IMAPError {
            throw error
        } catch {
            throw .connectionClosed
        }
    }

    /// 次に送る命令の応答を待つ準備をする。
    func expect(tag: String, on eventLoop: EventLoop) -> PendingResult {
        let promise = eventLoop.makePromise(of: [Response].self)
        eventLoop.execute {
            self.current = (tag, promise, [])
        }
        return PendingResult(future: promise.futureResult)
    }

    struct PendingResult {
        let future: EventLoopFuture<[Response]>

        func wait() async throws(IMAPError) -> [Response] {
            do {
                return try await future.get()
            } catch let error as IMAPError {
                throw error
            } catch {
                throw .connectionClosed
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if !greetingReceived {
            greetingReceived = true
            if case let .fatal(text) = response {
                greeting?.fail(IMAPError.connectionFailed(text.text))
            } else {
                greeting?.succeed()
            }
            greeting = nil
            return
        }
        switch response {
        case let .tagged(tagged) where tagged.tag == current?.tag:
            guard let pending = current else { return }
            current = nil
            switch tagged.state {
            case .ok:
                pending.promise.succeed(pending.responses)
            case let .no(text), let .bad(text):
                pending.promise.fail(IMAPError.commandFailed(text.text))
            }
        case let .fatal(text):
            // LOGOUT への BYE は正常なので、命令の結果を待つ
            if current == nil { fail(IMAPError.commandFailed(text.text)) }
        default:
            current?.responses.append(response)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(IMAPError.connectionClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(IMAPError.unexpectedResponse(String(describing: error)))
        context.close(promise: nil)
    }

    private func fail(_ error: IMAPError) {
        greeting?.fail(error)
        greeting = nil
        current?.promise.fail(error)
        current = nil
    }
}
