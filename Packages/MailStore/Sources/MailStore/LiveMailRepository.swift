import Foundation
import MailCore

/// 本物のメール (同期して保存したもの) を画面に渡す窓口。仮データの `PreviewMailRepository` と差し替えて使う。
public struct LiveMailRepository: MailRepository {
    public typealias MessageFetcher = @Sendable (StoredMessage) async throws -> Data
    public typealias SessionOpener = @Sendable (AccountID) async throws -> any MailServerSession
    public typealias SenderOpener = @Sendable (AccountID) async throws -> any MailSendingSession

    private let store: any MessageStore
    private let accountList: @Sendable () async throws -> [Account]
    private let fetchMessage: MessageFetcher?
    private let openSession: SessionOpener?
    private let openSender: SenderOpener?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - accounts: いま登録されているアカウント。削除されたアカウントのメールは出さない。
    ///   - fetchMessage: まだ保存していない本文をサーバーから取る。nil なら `openSession` で取る。
    ///   - openSession: 整理の操作 (と本文の取得、送ったメールの保存) のためにサーバーにつなぐ。使い終わったら閉じる。
    ///   - openSender: 送信のために、送信用のサーバー (SMTP) につなぐ。
    public init(
        store: any MessageStore,
        accounts: @escaping @Sendable () async throws -> [Account],
        fetchMessage: MessageFetcher? = nil,
        openSession: SessionOpener? = nil,
        openSender: SenderOpener? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        accountList = accounts
        self.openSession = openSession
        self.openSender = openSender
        self.now = now
        if let fetchMessage {
            self.fetchMessage = fetchMessage
        } else if let openSession {
            self.fetchMessage = { stored in
                try await Self.using(openSession, account: stored.summary.accountID) { session in
                    try await session.fetchMessage(in: stored.mailbox, uid: stored.uid)
                }
            }
        } else {
            self.fetchMessage = nil
        }
    }

    public func accounts() async throws -> [Account] {
        try await accountList()
    }

    public func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        // 絞り込みと並べ替えは保存先に任せる (何年分あっても、全部を読み込まない)
        try await store.summaries(matching: MessageQuery(accounts: registeredAccountIDs(), selection: selection, filter: filter))
    }

    public func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary] {
        try await store.summaries(matching: MessageQuery(accounts: registeredAccountIDs(), selection: nil, filter: filter, searchText: text))
    }

    /// 受信トレイ (と、それを絞り込んだ「未読」) は、サーバーから聞いた数があればそれを使う。
    /// まだ聞けていないアカウントと、ほかのフォルダは、保存しているメールを数える。
    public func unreadCount(in selection: MailboxSelection) async throws -> Int {
        let registered = try await accountList()
        let localCount = { (accounts: Set<AccountID>) in
            try await store.unreadCount(matching: MessageQuery(accounts: accounts, selection: selection))
        }
        guard selection.role == .inbox || selection.role == .unread else { return try await localCount(Set(registered.map(\.id))) }

        let accounts = registered.filter { selection.accountID == nil || $0.id == selection.accountID }
        var total = 0
        for account in accounts {
            if let fromServer = try await store.inboxUnreadCount(account: account.id) {
                total += fromServer
            } else {
                total += try await localCount([account.id])
            }
        }
        return total
    }

    public func labels(for account: AccountID) async throws -> [String] {
        guard try await registeredAccountIDs().contains(account) else { return [] }
        return try await store.labels(account: account)
    }

    /// 本文。初めて開いたときはサーバーから取って保存し、一覧の書き出しも埋める。2 回目からは保存分を使う。
    public func body(for id: MessageID) async throws -> MessageBody {
        let raw = try await rawMessage(for: id)
        return try MessageBodyBuilder.body(id: id, raw: raw)
    }

    public func attachmentData(for id: MessageID, index: Int) async throws -> Data {
        try MessageBodyBuilder.attachmentData(raw: try await rawMessage(for: id), index: index)
    }

    private func rawMessage(for id: MessageID) async throws -> Data {
        let ids = Set(try await accountList().map(\.id))
        guard let stored = try await store.message(id: id), ids.contains(stored.summary.accountID) else {
            throw MailRepositoryError.messageNotFound(id)
        }
        if let saved = try await store.rawMessage(for: id) { return saved }
        guard let fetchMessage else { throw MailRepositoryError.bodyUnavailable }

        let raw = try await fetchMessage(stored)
        try await store.setRawMessage(raw, for: id)
        if let body = try? MessageBodyBuilder.body(id: id, raw: raw) {
            var updated = stored
            updated.summary.preview = MessageBodyBuilder.preview(of: body)
            try await store.upsert([updated])
        }
        return raw
    }

    // MARK: - 整理の操作

    public func perform(_ action: MessageAction, on id: MessageID) async throws {
        guard let openSession else { throw MailRepositoryError.actionUnavailable }
        let accounts = try await accountList()
        guard let stored = try await store.message(id: id),
              let account = accounts.first(where: { $0.id == stored.summary.accountID }) else {
            throw MailRepositoryError.messageNotFound(id)
        }

        // 1. 何をするかを決める (できない操作や、移す先のフォルダがないときは、何も変えずに断る)
        let destination = try await destination(for: action, account: account, mailbox: stored.summary.mailbox)
        let updated = try Self.applying(action, to: stored, gmail: account.provider == .gmail)
        guard updated != stored else { return }

        // 2. 画面にすぐ出るよう先に保存先を変え、3. サーバーに送る。断られたら元に戻して投げる
        try await commit([(stored, updated)], action: action, account: account, destination: destination, openSession: openSession)
    }

    /// まとめて操作する (T26)。アカウントとフォルダごとにまとめて、サーバーへは 1 回で送る。
    /// - できないメール (受信トレイ以外のアーカイブなど) と、もうそうなっているメールは飛ばす。
    /// - あるサーバーが断ったら、そのまとまりだけ元に戻し、ほかは続けて、最後に最初の失敗を投げる。
    /// - 1 通だけのときは `perform(_:on:)` と同じ (できない操作は断る)。
    public func perform(_ action: MessageAction, on ids: [MessageID]) async throws {
        if ids.count == 1, let id = ids.first { return try await perform(action, on: id) }
        guard let openSession else { throw MailRepositoryError.actionUnavailable }
        let accounts = try await accountList()

        // アカウントとフォルダごとに分ける (選んだ順を保つ)
        struct GroupKey: Hashable { let account: AccountID; let mailbox: String }
        var groups: [GroupKey: [StoredMessage]] = [:]
        var order: [GroupKey] = []
        for id in ids {
            guard let stored = try await store.message(id: id) else { continue }
            let key = GroupKey(account: stored.summary.accountID, mailbox: stored.mailbox)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(stored)
        }

        var firstError: (any Error)?
        for key in order {
            guard let account = accounts.first(where: { $0.id == key.account }), let messages = groups[key] else { continue }
            do {
                let gmail = account.provider == .gmail
                var changes: [(StoredMessage, StoredMessage)] = []
                var destination: String?
                for stored in messages {
                    guard let updated = try? Self.applying(action, to: stored, gmail: gmail), updated != stored else { continue }
                    if changes.isEmpty {
                        destination = try await self.destination(for: action, account: account, mailbox: stored.summary.mailbox)
                    }
                    changes.append((stored, updated))
                }
                guard !changes.isEmpty else { continue }
                try await commit(changes, action: action, account: account, destination: destination, openSession: openSession)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// 操作したあとのメール (保存先に書く形)。このメールにできない操作なら `actionNotApplicable`。
    private static func applying(_ action: MessageAction, to stored: StoredMessage, gmail: Bool) throws -> StoredMessage {
        var updated = stored
        switch action {
        case .markRead: updated.summary.isRead = true
        case .markUnread: updated.summary.isRead = false
        case .star, .unstar:
            updated.summary.isStarred = action == .star
            updated.summary.isFlagged = action == .star
        case .archive:
            guard stored.summary.mailbox == .inbox else { throw MailRepositoryError.actionNotApplicable }
            updated.summary.mailbox = .archive
            if gmail {
                updated.labels = stored.labels.filter { $0.caseInsensitiveCompare("\\Inbox") != .orderedSame }
            }
        case .moveToTrash, .markAsJunk:
            let role: MailboxRole = action == .moveToTrash ? .trash : .junk
            guard stored.summary.mailbox != role else { throw MailRepositoryError.actionNotApplicable }
            updated.summary.mailbox = role
        }
        return updated
    }

    /// 移す先のフォルダ (移す操作のときだけ)。Gmail のアーカイブはラベルを外すだけなので要らない。
    /// 先にできるかを確かめ、できない操作ならフォルダを探さずに断る (`applying` と同じ順)。
    private func destination(for action: MessageAction, account: Account, mailbox: MailboxRole) async throws -> String? {
        switch action {
        case .markRead, .markUnread, .star, .unstar:
            return nil
        case .archive:
            guard mailbox == .inbox else { throw MailRepositoryError.actionNotApplicable }
            return account.provider == .gmail ? nil : try await folder(for: .archive, account: account.id)
        case .moveToTrash, .markAsJunk:
            let role: MailboxRole = action == .moveToTrash ? .trash : .junk
            guard mailbox != role else { throw MailRepositoryError.actionNotApplicable }
            return try await folder(for: role, account: account.id)
        }
    }

    /// 同じアカウント・同じフォルダのメールの変更を、保存先に書いてからサーバーに 1 回で送る。
    /// サーバーが断ったら、保存先を元に戻して投げる。
    private func commit(
        _ changes: [(old: StoredMessage, new: StoredMessage)], action: MessageAction, account: Account,
        destination: String?, openSession: SessionOpener
    ) async throws {
        guard let first = changes.first else { return }
        let gmail = account.provider == .gmail

        // 画面にすぐ出るよう、先に保存先を変える (受信トレイの未読数も合わせる)
        let previousUnread = try await store.inboxUnreadCount(account: account.id)
        try await store.upsert(changes.map(\.new))
        let delta = changes.reduce(0) { $0 + Self.unreadInboxCount($1.new) - Self.unreadInboxCount($1.old) }
        if delta != 0, let previousUnread {
            try await store.setInboxUnreadCount(max(0, previousUnread + delta), account: account.id)
        }

        do {
            try await Self.using(openSession, account: account.id) { session in
                let mailbox = first.old.mailbox
                let uids = changes.map(\.old.uid)
                switch action {
                case .markRead, .markUnread:
                    try await session.setFlags(["\\Seen"], add: action == .markRead, in: mailbox, uids: uids)
                case .star, .unstar:
                    try await session.setFlags(["\\Flagged"], add: action == .star, in: mailbox, uids: uids)
                case .archive where gmail:
                    try await session.setGmailLabels(["\\Inbox"], add: false, in: mailbox, uids: uids)
                case .archive, .moveToTrash, .markAsJunk:
                    guard let destination else { throw MailRepositoryError.actionNotApplicable }
                    try await session.move(uids: uids, from: mailbox, to: destination)
                }
            }
        } catch {
            try? await store.upsert(changes.map(\.old))
            if let previousUnread { try? await store.setInboxUnreadCount(previousUnread, account: account.id) }
            throw error
        }
    }

    // MARK: - 受信トレイをすべて既読にする

    /// 1 回の `UID STORE` で送る数 (命令が長くなりすぎないように)。
    static let markReadChunkSize = 500

    /// 受信トレイをすべて既読にする。Mac に保存していない古い未読も、サーバーで探して既読にする。
    /// 先にサーバーを変え、うまくいったアカウントだけ Mac の保存先を合わせる (断られたら、Mac は未読のまま)。
    /// つながらないアカウントがあっても、ほかは続けて、最後に最初の失敗を投げる。
    public func markInboxRead(account accountID: AccountID?) async throws -> Int {
        guard let openSession else { throw MailRepositoryError.actionUnavailable }
        let targets = try await accountList().filter { accountID == nil || $0.id == accountID }
        var marked = 0
        var firstError: (any Error)?
        for account in targets {
            do {
                // Gmail も、ほかのサーバーも、受信トレイは「INBOX」という名前で開ける
                let (count, unreadLeft) = try await Self.using(openSession, account: account.id) { session in
                    let uids = try await session.searchUnreadUIDs(in: "INBOX")
                    for start in stride(from: 0, to: uids.count, by: Self.markReadChunkSize) {
                        let chunk = Array(uids[start ..< min(start + Self.markReadChunkSize, uids.count)])
                        try await session.setFlags(["\\Seen"], add: true, in: "INBOX", uids: chunk)
                    }
                    // 探したあとに届いた新着は未読のまま残るので、数はサーバーに聞き直す
                    return (uids.count, try? await session.unreadCount(of: "INBOX"))
                }
                marked += count
                let unread = try await store.summaries(matching: MessageQuery(accounts: [account.id], selection: .unified(.inbox)))
                    .filter { !$0.isRead }
                var updated: [StoredMessage] = []
                for summary in unread {
                    guard var stored = try await store.message(id: summary.id) else { continue }
                    stored.summary.isRead = true
                    updated.append(stored)
                }
                try await store.upsert(updated)
                try await store.setInboxUnreadCount(unreadLeft ?? 0, account: account.id)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return marked
    }

    // MARK: - 返信と送信 (T18)

    public func replySource(for id: MessageID) async throws -> ReplySource {
        let raw = try await rawMessage(for: id)
        guard let stored = try await store.message(id: id) else { throw MailRepositoryError.messageNotFound(id) }
        return try Self.replySource(raw: raw, id: id, stored: stored)
    }

    /// メールの全体から、返信・転送に使う情報を作る (サーバー側の検索で見つけたメールにも使う、T27)。
    static func replySource(raw: Data, id: MessageID, stored: StoredMessage) throws -> ReplySource {
        let parsed = try MIMEParser.parse(raw)
        let body = try MessageBodyBuilder.body(id: id, raw: raw)
        let contacts = { (addresses: [EmailAddress]) in addresses.map { Contact(name: $0.name, address: $0.address) } }
        return ReplySource(
            accountID: stored.summary.accountID,
            from: contacts(parsed.from),
            replyTo: contacts(parsed.replyTo),
            to: contacts(parsed.to),
            cc: contacts(parsed.cc),
            subject: parsed.subject,
            date: parsed.date ?? stored.summary.date,
            messageID: parsed.messageID,
            references: parsed.references,
            text: body.text,
            attachments: parsed.attachments.filter { !$0.isInline }.map {
                DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        )
    }

    /// 送る。宛先が 1 つでも断られたら、誰にも送らない (`SMTPSession` の決まり)。
    /// Gmail は送信したメールを自動で「送信済み」に入れるので、それ以外のときだけ `APPEND` する。
    public func send(_ draft: Draft) async throws -> SendOutcome {
        if let problem = Composer.problem(in: draft) { throw problem }
        guard let openSender else { throw MailRepositoryError.actionUnavailable }
        guard let account = try await accountList().first(where: { $0.id == draft.accountID }) else {
            throw DraftProblem.noAccount
        }

        // 差出人の名前 (設定で決めたもの)。空ならアドレスだけ
        let from = EmailAddress(name: account.senderName, address: account.emailAddress)
        let address = { (contacts: [Contact]) in contacts.map { EmailAddress(name: $0.name, address: $0.address) } }
        let message = OutgoingMessage(
            from: from,
            to: address(draft.to),
            cc: address(draft.cc),
            bcc: address(draft.bcc),
            subject: draft.subject,
            textBody: draft.body,
            attachments: draft.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            date: now(),
            messageID: MIMEBuilder.makeMessageID(for: from)
        )
        let data = try MIMEBuilder.build(message)

        let sender = try await openSender(account.id)
        do {
            try await sender.send(data, from: account.emailAddress, to: message.envelopeRecipients)
        } catch {
            await sender.close()
            throw error
        }
        await sender.close()

        guard account.provider != .gmail else { return .sent }
        // ここから先は送信済み。失敗しても「送れなかった」とは言わず、残せなかったことだけを知らせる
        do {
            guard let openSession else { throw MailRepositoryError.actionUnavailable }
            let folder = try await folder(for: .sent, account: account.id)
            try await Self.using(openSession, account: account.id) { session in
                try await session.append(data, to: folder, flags: ["\\Seen"])
            }
            return .sent
        } catch {
            return .sentButNotSaved(String(describing: error))
        }
    }

    private func folder(for role: MailboxRole, account: AccountID) async throws -> String {
        guard let name = try await store.mailboxName(for: role, account: account) else {
            throw MailRepositoryError.noFolder(role)
        }
        return name
    }

    /// 受信トレイの未読なら 1。
    private static func unreadInboxCount(_ message: StoredMessage) -> Int {
        message.summary.mailbox == .inbox && !message.summary.isRead ? 1 : 0
    }

    /// サーバーにつないで作業し、成功しても失敗しても閉じる。
    private static func using<T: Sendable>(
        _ openSession: SessionOpener, account: AccountID, _ work: (any MailServerSession) async throws -> T
    ) async throws -> T {
        let session = try await openSession(account)
        do {
            let result = try await work(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    /// 登録中のアカウント (削除したアカウントのメールは出さない)。
    private func registeredAccountIDs() async throws -> Set<AccountID> {
        Set(try await accountList().map(\.id))
    }
}
