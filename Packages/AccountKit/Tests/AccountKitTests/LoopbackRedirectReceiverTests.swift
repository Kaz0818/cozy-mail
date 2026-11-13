import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import AccountKit

/// ブラウザの代わりに、生の HTTP リクエストを送って応答を読む。
private func sendRequest(_ request: String, port: Int) async throws -> String {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .connect(host: "127.0.0.1", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
        }
    return try await channel.executeThenClose { inbound, outbound in
        try await outbound.write(ByteBuffer(string: request))
        var response = ""
        for try await var chunk in inbound {
            response += chunk.readString(length: chunk.readableBytes) ?? ""
        }
        return response
    }
}

@Suite struct LoopbackRedirectReceiverTests {
    @Test func receivesTheRedirectAndShowsAThankYouPage() async throws {
        let receiver = try await LoopbackRedirectReceiver.start()
        #expect(receiver.redirectURI.hasPrefix("http://127.0.0.1:"))

        async let redirect = receiver.waitForRedirect()
        let response = try await sendRequest(
            "GET /?state=s1&code=abc HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", port: receiver.port
        )
        let url = try await redirect

        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(response.contains("Cozy Mail"))
        #expect(try OAuthClient.authorizationCode(from: url, expectedState: "s1") == "abc")
    }

    @Test func ignoresFaviconRequestsAndKeepsWaiting() async throws {
        let receiver = try await LoopbackRedirectReceiver.start()
        async let redirect = receiver.waitForRedirect()

        let favicon = try await sendRequest("GET /favicon.ico HTTP/1.1\r\nHost: x\r\n\r\n", port: receiver.port)
        _ = try await sendRequest("GET /?state=s&code=real HTTP/1.1\r\nHost: x\r\n\r\n", port: receiver.port)
        let url = try await redirect

        #expect(favicon.hasPrefix("HTTP/1.1 404"))
        #expect(url.query?.contains("code=real") == true)
    }
}
