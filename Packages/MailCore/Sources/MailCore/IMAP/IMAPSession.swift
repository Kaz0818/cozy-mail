import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL

/// 1 つのメールアカウントへの IMAP 接続。命令は 1 つずつ順に送る。
public actor IMAPSession {
    private let channel: Channel
    private let collector: ResponseCollector
    private var nextTag = 1

    private init(channel: Channel, collector: ResponseCollector) {
        self.channel = channel
        self.collector = collector
    }

    // MARK: - 接続とログイン

    /// 接続してログインする。
    public static func connect(to server: IMAPServer, credentials: IMAPCredentials) async throws(IMAPError) -> IMAPSession {
        let collector = ResponseCollector()
        let channel: Channel
        do {
            let sslContext: NIOSSLContext? = server.security == .tls
                ? try NIOSSLContext(configuration: .makeClientConfiguration())
                : nil
            channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.seconds(20))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let pipeline = channel.pipeline.syncOperations
                        if let sslContext {
                            try pipeline.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: server.host))
                        }
                        try pipeline.addHandler(IMAPClientHandler())
                        try pipeline.addHandler(collector)
                    }
                }
                .connect(host: server.host, port: server.port)
                .get()
        } catch {
            throw .connectionFailed(String(describing: error))
        }

        let session = IMAPSession(channel: channel, collector: collector)
        do {
            try await collector.waitForGreeting(on: channel.eventLoop)
            try await session.login(credentials)
        } catch {
            try? await channel.close()
            throw error
        }
        return session
    }

    private func login(_ credentials: IMAPCredentials) async throws(IMAPError) {
        switch credentials {
        case let .password(username, password):
            do {
                _ = try await run(.login(username: username, password: password))
            } catch let .commandFailed(reason) {
                throw .authenticationFailed(reason)
            }
        }
    }

    /// ログアウトして接続を閉じる。失敗しても気にしない。
    public func logout() async {
        _ = try? await run(.logout)
        try? await channel.close()
    }

    // MARK: - フォルダ

    public func listMailboxes() async throws(IMAPError) -> [IMAPMailbox] {
        let responses = try await run(.list(nil, reference: MailboxName(ByteBuffer()), .mailbox(ByteBuffer(string: "*"))))
        return responses.compactMap { response in
            guard case let .untagged(.mailboxData(.list(info))) = response else { return nil }
            return IMAPMailbox(info)
        }
    }

    /// 読み取り専用でフォルダを開き、件数などを返す。
    public func examine(_ mailbox: String) async throws(IMAPError) -> IMAPMailboxStatus {
        let responses = try await run(.examine(MailboxName(ByteBuffer(string: mailbox))))
        var status = IMAPMailboxStatus(messageCount: 0, uidValidity: 0, uidNext: nil)
        for response in responses {
            switch response {
            case let .untagged(.mailboxData(.exists(count))):
                status.messageCount = count
            case let .untagged(.conditionalState(.ok(text))):
                switch text.code {
                case let .uidValidity(value): status.uidValidity = UInt32(value)
                case let .uidNext(value): status.uidNext = value.rawValue
                default: break
                }
            default:
                break
            }
        }
        return status
    }

    // MARK: - メール

    /// フォルダの新しい方から `count` 通の見出しを、新しい順に返す。
    public func fetchLatestHeaders(in mailbox: String, count: Int) async throws(IMAPError) -> [IMAPFetchedHeader] {
        let status = try await examine(mailbox)
        guard status.messageCount > 0, count > 0 else { return [] }
        let first = max(1, status.messageCount - count + 1)
        let range = MessageIdentifierRange<SequenceNumber>(
            SequenceNumber(rawValue: UInt32(first))...SequenceNumber(rawValue: UInt32(status.messageCount))
        )
        let responses = try await run(.fetch(
            .set(MessageIdentifierSetNonEmpty(range: range)),
            [.uid, .flags, .rfc822Size, .bodySection(peek: true, .header, nil)],
            []
        ))
        return FetchAssembler.headers(from: responses).sorted { $0.uid > $1.uid }
    }

    // MARK: - 命令の送受信

    private func run(_ command: Command) async throws(IMAPError) -> [Response] {
        let tag = "C\(nextTag)"
        nextTag += 1
        let result = collector.expect(tag: tag, on: channel.eventLoop)
        do {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: command))))
        } catch {
            throw .connectionClosed
        }
        return try await result.wait()
    }
}

private extension IMAPMailbox {
    init(_ info: MailboxInfo) {
        let components = info.path.displayStringComponents(omittingEmptySubsequences: false)
        let separator = info.path.pathSeparator
        name = components.joined(separator: separator.map(String.init) ?? "")
        rawName = String(buffer: ByteBuffer(bytes: info.path.name.bytes))
        self.separator = separator
        isSelectable = !info.attributes.contains(.noSelect)

        let attributes = Set(info.attributes.map { String($0).lowercased() })
        if rawName.uppercased() == "INBOX" {
            specialUse = .inbox
        } else {
            specialUse = [
                ("\\all", IMAPSpecialUse.all), ("\\archive", .archive), ("\\drafts", .drafts),
                ("\\flagged", .flagged), ("\\junk", .junk), ("\\sent", .sent), ("\\trash", .trash),
            ].first { attributes.contains($0.0) }?.1
        }
    }
}

/// `FETCH` の応答 (細切れで届く) を 1 通ずつにまとめる。
enum FetchAssembler {
    static func headers(from responses: [Response]) -> [IMAPFetchedHeader] {
        var results: [IMAPFetchedHeader] = []
        var current: IMAPFetchedHeader?
        var isReadingHeader = false
        for response in responses {
            guard case let .fetch(part) = response else { continue }
            switch part {
            case .start, .startUID:
                current = IMAPFetchedHeader(uid: 0, flags: [], size: nil, headerData: Data())
            case let .simpleAttribute(attribute):
                switch attribute {
                case let .uid(uid): current?.uid = uid.rawValue
                case let .flags(flags): current?.flags = flags.map(String.init)
                case let .rfc822Size(size): current?.size = size
                default: break
                }
            case let .streamingBegin(kind, _):
                if case let .body(section, _) = kind { isReadingHeader = section.kind == .header }
            case let .streamingBytes(bytes):
                if isReadingHeader { current?.headerData.append(contentsOf: bytes.readableBytesView) }
            case .streamingEnd:
                isReadingHeader = false
            case .finish:
                if let message = current { results.append(message) }
                current = nil
            }
        }
        return results
    }
}
