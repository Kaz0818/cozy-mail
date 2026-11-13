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
    /// いま開いているフォルダ。同じフォルダへの命令が続くときに、開き直さないため。
    private var examinedMailbox: String?

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
        let command: Command = switch credentials {
        case let .password(username, password):
            .login(username: username, password: password)
        case let .oauth2(username, accessToken):
            .authenticate(
                mechanism: AuthenticationMechanism("XOAUTH2"),
                initialResponse: InitialResponse(ByteBuffer(string: XOAuth2.initialResponse(
                    username: username, accessToken: accessToken
                )))
            )
        }
        do {
            _ = try await run(command)
        } catch let .commandFailed(reason) {
            throw .authenticationFailed(reason)
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
        examinedMailbox = nil
        let responses = try await run(.examine(MailboxName(ByteBuffer(string: mailbox))))
        examinedMailbox = mailbox
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

    /// メール 1 通の全体 (ヘッダー・本文・添付) を取る。`BODY.PEEK[]` なので既読にはならない。
    public func fetchMessage(in mailbox: String, uid: UInt32) async throws(IMAPError) -> Data {
        let set = MessageIdentifierSetNonEmpty<UID>(range: MessageIdentifierRange(UID(rawValue: uid)))
        let fetched = try await fetch(in: mailbox, set: set, attributes: [.uid, .bodySection(peek: true, .complete, nil)])
        guard let message = fetched.first(where: { $0.uid == uid }), !message.messageData.isEmpty else {
            throw .messageNotFound(uid: uid)
        }
        return message.messageData
    }

    /// フォルダの未読数をサーバーに聞く (`STATUS (UNSEEN)`)。フォルダを開かずに聞ける。
    public func unreadCount(of mailbox: String) async throws(IMAPError) -> Int {
        let responses = try await run(.status(MailboxName(ByteBuffer(string: mailbox)), [.unseenCount]))
        for response in responses {
            if case let .untagged(.mailboxData(.status(_, status))) = response, let unseen = status.unseenCount {
                return unseen
            }
        }
        throw .unexpectedResponse("STATUS の応答に UNSEEN がありません")
    }

    /// 指定した日付以降に届いたメールの UID を、小さい順に返す (`UID SEARCH SINCE`)。
    /// 日付は `calendar` のタイムゾーンでの日にちとして送る (IMAP の SINCE は時刻を持たない)。
    public func searchUIDs(
        in mailbox: String, since date: Date, calendar: Calendar = .current
    ) async throws(IMAPError) -> [UInt32] {
        try await ensureExamined(mailbox)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day,
              let calendarDay = IMAPCalendarDay(year: year, month: month, day: day) else {
            throw .unexpectedResponse("日付を IMAP の形にできません: \(date)")
        }
        let responses = try await run(.uidSearch(key: .since(calendarDay)))
        var uids: [UInt32] = []
        for response in responses {
            if case let .untagged(.mailboxData(.search(ids, _))) = response {
                uids.append(contentsOf: ids.map(\.rawValue))
            }
        }
        return uids.sorted()
    }

    /// UID を指定して見出しを取る。UID の小さい順に返す。サーバーにない UID は結果に含まれない。
    public func fetchHeaders(
        in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool
    ) async throws(IMAPError) -> [IMAPFetchedHeader] {
        var results: [IMAPFetchedHeader] = []
        // 1 回の命令が長くなりすぎないよう、500 件ずつに分ける
        let sorted = Array(Set(uids)).sorted()
        for start in stride(from: 0, to: sorted.count, by: 500) {
            let chunk = Array(sorted[start..<min(start + 500, sorted.count)])
            guard let set = Self.uidSet(chunk) else { continue }
            results += try await fetch(in: mailbox, set: set, attributes: Self.headerAttributes(gmail: includeGmailAttributes))
        }
        return results.sorted { $0.uid < $1.uid }
    }

    /// `uid` 以降 (`uid:*`) の見出しを取る。
    /// 注意: IMAP の決まりで、`uid` より大きいメールがなくても最後の 1 通が返ることがある。呼ぶ側で `uid` 未満を捨てること。
    public func fetchHeaders(
        in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool
    ) async throws(IMAPError) -> [IMAPFetchedHeader] {
        let set = MessageIdentifierSetNonEmpty<UID>(range: MessageIdentifierRange(UID(rawValue: max(uid, 1))...))
        return try await fetch(in: mailbox, set: set, attributes: Self.headerAttributes(gmail: includeGmailAttributes))
            .sorted { $0.uid < $1.uid }
    }

    /// 範囲内のメールのフラグ (と Gmail のラベル) だけを取り直す。消えたメールは結果に含まれない。
    public func fetchFlags(
        in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool
    ) async throws(IMAPError) -> [IMAPFetchedHeader] {
        let range = MessageIdentifierRange<UID>(UID(rawValue: max(uids.lowerBound, 1))...UID(rawValue: max(uids.upperBound, 1)))
        var attributes: [FetchAttribute] = [.uid, .flags]
        if includeGmailAttributes { attributes += [.gmailMessageID, .gmailLabels] }
        return try await fetch(in: mailbox, set: MessageIdentifierSetNonEmpty(range: range), attributes: attributes)
            .sorted { $0.uid < $1.uid }
    }

    private static func headerAttributes(gmail: Bool) -> [FetchAttribute] {
        var attributes: [FetchAttribute] = [.uid, .flags, .rfc822Size, .bodySection(peek: true, .header, nil)]
        if gmail { attributes += [.gmailMessageID, .gmailThreadID, .gmailLabels] }
        return attributes
    }

    /// 並んだ UID を `101:102,105` のような範囲の集まりにする。
    private static func uidSet(_ sortedUIDs: [UInt32]) -> MessageIdentifierSetNonEmpty<UID>? {
        var ranges: [MessageIdentifierRange<UID>] = []
        var start: UInt32?
        var previous: UInt32 = 0
        for uid in sortedUIDs where uid > 0 {
            if start != nil, uid == previous + 1 {
                previous = uid
                continue
            }
            if let first = start { ranges.append(MessageIdentifierRange(UID(rawValue: first)...UID(rawValue: previous))) }
            start = uid
            previous = uid
        }
        if let first = start { ranges.append(MessageIdentifierRange(UID(rawValue: first)...UID(rawValue: previous))) }
        return MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges))
    }

    private func ensureExamined(_ mailbox: String) async throws(IMAPError) {
        if examinedMailbox != mailbox { _ = try await examine(mailbox) }
    }

    private func fetch(
        in mailbox: String, set: MessageIdentifierSetNonEmpty<UID>, attributes: [FetchAttribute]
    ) async throws(IMAPError) -> [IMAPFetchedHeader] {
        try await ensureExamined(mailbox)
        let responses = try await run(.uidFetch(.set(set), attributes, []))
        return FetchAssembler.headers(from: responses)
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
        /// いま届いている塊を、どこに貯めるか。
        enum Target { case none, header, message }
        var target = Target.none
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
                case let .gmailMessageID(id): current?.gmailMessageID = id
                case let .gmailThreadID(id): current?.gmailThreadID = id
                case let .gmailLabels(labels): current?.gmailLabels = labels.map { $0.makeDisplayString() }
                default: break
                }
            case let .streamingBegin(kind, _):
                switch kind {
                case let .body(section, _) where section.part == [] && section.kind == .header: target = .header
                case let .body(section, _) where section.part == [] && section.kind == .complete: target = .message
                case .rfc822Header: target = .header
                case .rfc822: target = .message
                default: target = .none
                }
            case let .streamingBytes(bytes):
                switch target {
                case .header: current?.headerData.append(contentsOf: bytes.readableBytesView)
                case .message: current?.messageData.append(contentsOf: bytes.readableBytesView)
                case .none: break
                }
            case .streamingEnd:
                target = .none
            case .finish:
                if let message = current { results.append(message) }
                current = nil
            }
        }
        return results
    }
}
