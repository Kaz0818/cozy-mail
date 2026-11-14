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
    /// いま開いているフォルダと、読み書きできる (SELECT) か読むだけ (EXAMINE) か。
    /// 同じフォルダへの命令が続くときに、開き直さないため。
    private var openMailbox: (name: String, writable: Bool)?
    /// サーバーが対応している機能 (大文字)。初めて必要になったときに CAPABILITY で聞く。
    private var capabilities: Set<String>?

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
        openMailbox = nil
        let responses = try await run(.examine(MailboxName(ByteBuffer(string: mailbox))))
        openMailbox = (mailbox, false)
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

    /// 読むために開く。読み書きで開いていれば、そのまま使う。
    private func ensureExamined(_ mailbox: String) async throws(IMAPError) {
        if openMailbox?.name != mailbox { _ = try await examine(mailbox) }
    }

    /// 書き込む (フラグを変える・移す) ために、読み書きで開く。
    private func ensureSelected(_ mailbox: String) async throws(IMAPError) {
        guard openMailbox?.name != mailbox || openMailbox?.writable != true else { return }
        openMailbox = nil
        _ = try await run(.select(MailboxName(ByteBuffer(string: mailbox))))
        openMailbox = (mailbox, true)
    }

    private func serverCapabilities() async throws(IMAPError) -> Set<String> {
        if let capabilities { return capabilities }
        var found: Set<String> = []
        for response in try await run(.capability) {
            if case let .untagged(.capabilityData(list)) = response {
                found.formUnion(list.map { String($0).uppercased() })
            }
        }
        capabilities = found
        return found
    }

    // MARK: - 整理の操作

    /// フラグ (`\Seen`、`\Flagged` など) を付ける・外す。
    public func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws(IMAPError) {
        guard let set = Self.uidSet(Array(Set(uids)).sorted()) else { return }
        try await ensureSelected(mailbox)
        let list = flags.map { Flag($0) }
        _ = try await run(.uidStore(.set(set), [], .flags(add ? .add(silent: true, list: list) : .remove(silent: true, list: list))))
    }

    /// Gmail のラベルを付ける・外す。アーカイブは「すべてのメール」で `\Inbox` を外すこと。
    public func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws(IMAPError) {
        guard let set = Self.uidSet(Array(Set(uids)).sorted()) else { return }
        try await ensureSelected(mailbox)
        let list = labels.map { GmailLabel(ByteBuffer(string: $0)) }
        _ = try await run(.uidStore(
            .set(set), [], .gmailLabels(add ? .add(silent: true, gmailLabels: list) : .remove(silent: true, gmailLabels: list))
        ))
    }

    /// 別のフォルダへ移す。MOVE があれば使い、なければ COPY して「削除の印」を付け、UIDPLUS があればそのメールだけを消す。
    /// UIDPLUS がないときは EXPUNGE しない (フォルダ内のほかの「削除の印」のメールまで消えてしまうため)。
    public func move(uids: [UInt32], from mailbox: String, to target: String) async throws(IMAPError) {
        guard let set = Self.uidSet(Array(Set(uids)).sorted()) else { return }
        try await ensureSelected(mailbox)
        let destination = MailboxName(ByteBuffer(string: target))
        let capabilities = try await serverCapabilities()
        if capabilities.contains("MOVE") {
            _ = try await run(.uidMove(.set(set), destination))
            return
        }
        _ = try await run(.uidCopy(.set(set), destination))
        _ = try await run(.uidStore(.set(set), [], .flags(.add(silent: true, list: [Flag("\\Deleted")]))))
        if capabilities.contains("UIDPLUS") {
            _ = try await run(.uidExpunge(.set(set)))
        }
    }

    private func fetch(
        in mailbox: String, set: MessageIdentifierSetNonEmpty<UID>, attributes: [FetchAttribute]
    ) async throws(IMAPError) -> [IMAPFetchedHeader] {
        try await ensureExamined(mailbox)
        let responses = try await run(.uidFetch(.set(set), attributes, []))
        return FetchAssembler.headers(from: responses)
    }

    // MARK: - 命令の送受信

    /// メールをフォルダに入れる (`APPEND`)。送ったメールを「送信済み」に残すのに使う。
    /// サーバーの「+」(続きをどうぞ) を待ってから本文を送る部分は、`IMAPClientHandler` が受け持つ。
    public func append(_ message: Data, to mailbox: String, flags: [String] = ["\\Seen"]) async throws(IMAPError) {
        let tag = "C\(nextTag)"
        nextTag += 1
        let result = collector.expect(tag: tag, on: channel.eventLoop)
        let parts: [AppendCommand] = [
            .start(tag: tag, appendingTo: MailboxName(ByteBuffer(string: mailbox))),
            .beginMessage(message: AppendMessage(
                options: AppendOptions(flagList: flags.map { Flag($0) }),
                data: AppendData(byteCount: message.count)
            )),
            .messageBytes(ByteBuffer(bytes: message)),
            .endMessage,
            .finish,
        ]
        // 本文は「+」が届くまで送られないので、書き込みの完了は待たずに、命令の結果を待つ
        for part in parts {
            channel.write(IMAPClientHandler.Message.part(.append(part)), promise: nil)
        }
        channel.flush()
        _ = try await result.wait()
    }

    // MARK: - 新着を待つ (IDLE、T20a)

    /// サーバーが IDLE (変わったら知らせる仕組み) に対応しているか。
    public func supportsIdle() async throws(IMAPError) -> Bool {
        try await serverCapabilities().contains("IDLE")
    }

    /// 何もしない命令。接続が生きているかを確かめる。
    public func noop() async throws(IMAPError) {
        _ = try await run(.noop)
    }

    /// フォルダを開いて IDLE に入り、変わった知らせ・時間切れ・作業の中止のどれかが来るまで待つ。
    /// 終わるときは DONE を送って IDLE を抜けるので、続けて別の命令を送れる。
    /// サーバーが IDLE を断った・接続が切れたときは投げる。
    /// DONE の返事が `doneTimeout` のあいだに来なければ、回線が黙って切れていると見なし、接続を閉じて投げる。
    public func idle(
        in mailbox: String, timeout: Duration, doneTimeout: Duration = .seconds(15)
    ) async throws(IMAPError) -> IMAPIdleEvent {
        try await ensureExamined(mailbox)
        let eventLoop = channel.eventLoop
        let tag = "C\(nextTag)"
        nextTag += 1
        let result = collector.expect(tag: tag, on: eventLoop)
        let changes = collector.watchForChanges(on: eventLoop)
        let race = IdleRace(eventLoop: eventLoop)
        changes.whenComplete { _ in race.finish(.changed) }
        // サーバーが自分で IDLE を終えた (断った、切れた)
        result.future.whenComplete { _ in race.serverEnded() }
        do {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: .idleStart))))
        } catch {
            throw .connectionClosed
        }
        let timer = eventLoop.scheduleTask(in: Self.timeAmount(timeout)) {
            race.finish(.timedOut)
        }
        let event = await withTaskCancellationHandler {
            await race.outcome()
        } onCancel: {
            race.finish(.cancelled)
        }
        timer.cancel()
        collector.stopWatchingForChanges(on: eventLoop)
        if await !race.hasServerEnded() {
            do {
                try await channel.writeAndFlush(IMAPClientHandler.Message.part(.idleDone))
            } catch {
                throw .connectionClosed
            }
            // DONE の返事を待つのは決めた時間まで。来なければ接続を閉じる (閉じると、待っている結果も失敗する)
            let channel = channel
            let watchdog = eventLoop.scheduleTask(in: Self.timeAmount(doneTimeout)) {
                channel.close(promise: nil)
            }
            defer { watchdog.cancel() }
            _ = try await result.wait()
        } else {
            _ = try await result.wait()
        }
        return event
    }

    private static func timeAmount(_ duration: Duration) -> TimeAmount {
        let (seconds, attoseconds) = duration.components
        return .nanoseconds(seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
    }

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

/// IDLE の「どれが先に来たか」をまとめる。状態はイベントループの上でだけ触る。
private final class IdleRace: @unchecked Sendable {
    private let eventLoop: EventLoop
    private let promise: EventLoopPromise<IMAPIdleEvent>
    private var finished = false
    private var ended = false

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        promise = eventLoop.makePromise(of: IMAPIdleEvent.self)
    }

    /// 最初に来たものだけを結果にする。
    func finish(_ event: IMAPIdleEvent) {
        eventLoop.execute {
            guard !self.finished else { return }
            self.finished = true
            self.promise.succeed(event)
        }
    }

    func serverEnded() {
        eventLoop.execute {
            self.ended = true
            if !self.finished {
                self.finished = true
                self.promise.succeed(.changed)
            }
        }
    }

    func outcome() async -> IMAPIdleEvent {
        (try? await promise.futureResult.get()) ?? .changed
    }

    func hasServerEnded() async -> Bool {
        (try? await eventLoop.submit { self.ended }.get()) ?? true
    }
}
