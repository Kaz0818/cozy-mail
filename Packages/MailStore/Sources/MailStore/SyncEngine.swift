import Foundation
import MailCore

/// メールサーバーとのやりとり。`IMAPSession` がそのまま当てはまる。テストでは偽物に差し替える。
public protocol MailServerSession: Sendable {
    func listMailboxes() async throws -> [IMAPMailbox]
    func examine(_ mailbox: String) async throws -> IMAPMailboxStatus
    func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32]
    func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader]
    func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader]
    func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader]
    /// フォルダ全体の未読数 (`STATUS (UNSEEN)`)。
    func unreadCount(of mailbox: String) async throws -> Int
    /// メール 1 通の全体。既読にはしない。
    func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data
    /// フラグ (`\Seen`、`\Flagged`) を付ける・外す。
    func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws
    /// Gmail のラベルを付ける・外す。
    func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws
    /// 別のフォルダへ移す。
    func move(uids: [UInt32], from mailbox: String, to target: String) async throws
    /// メールをフォルダに入れる (送ったメールを「送信済み」に残す)。
    func append(_ message: Data, to mailbox: String, flags: [String]) async throws
    /// ログアウトして接続を閉じる。
    func close() async
    /// サーバーが IDLE (変わったら知らせる仕組み) に対応しているか (T20a)。
    func supportsIdle() async throws -> Bool
    /// フォルダの変化・時間切れ・作業の中止のどれかまで待つ (T20a)。
    func idle(in mailbox: String, timeout: Duration) async throws -> IMAPIdleEvent
}

extension MailServerSession {
    /// IDLE を使わない接続 (テストの偽物など) は、対応していないことにする。
    public func supportsIdle() async throws -> Bool { false }

    public func idle(in mailbox: String, timeout: Duration) async throws -> IMAPIdleEvent {
        throw IMAPError.commandFailed("IDLE is not supported")
    }
}

extension IMAPSession: MailServerSession {
    public func close() async {
        await logout()
    }
}

/// 送信用 (SMTP) の接続。
public protocol MailSendingSession: Sendable {
    /// 組み立て済みのメールを送る。
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws
    /// 送信を終えて接続を閉じる。
    func close() async
}

extension SMTPSession: MailSendingSession {
    public func close() async {
        await quit()
    }
}

/// サーバーのメールを Mac の保存先に同期する (SPEC 6.2)。
///
/// - 初回 (または `UIDVALIDITY` が変わったとき): 最近 30 日分の見出しを取る。
/// - 2 回目以降: 前回より大きい UID の見出しを取り、取得済みの範囲はフラグだけ取り直す。返ってこなかったメールは削除されたとみなす。
/// - Gmail: 同じメールが「受信トレイ」と「すべてのメール」の両方に入っているので、「すべてのメール」「迷惑メール」「ゴミ箱」だけを同期し、
///   受信トレイ・送信済み・下書きの区別はラベル (`X-GM-LABELS`) で決める。これで二重に表示されない。
public struct SyncEngine: Sendable {
    /// 同期するフォルダ。`role` が nil なら、メールごとに Gmail のラベルで決める。
    public struct Target: Sendable, Hashable {
        /// サーバー上の名前 (修正 UTF-7 のまま。命令にはこれを使う)。
        public let name: String
        public let role: MailboxRole?
    }

    public struct Report: Sendable, Hashable {
        public var added = 0
        public var updated = 0
        public var removed = 0
    }

    private let store: any MessageStore
    private let initialWindow: TimeInterval
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        store: any MessageStore,
        initialWindowDays: Int = 30,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        initialWindow = TimeInterval(initialWindowDays) * 86400
        self.calendar = calendar
        self.now = now
    }

    public func sync(account: Account, session: some MailServerSession) async throws -> Report {
        let mailboxes = try await session.listMailboxes()
        let targets = Self.targets(for: account.provider, mailboxes: mailboxes)
        // 整理の操作 (ゴミ箱・迷惑メール・アーカイブへ移す) で使うので、役割ごとのフォルダ名を覚えておく
        var names: [MailboxRole: String] = [:]
        for target in targets {
            if let role = target.role, names[role] == nil { names[role] = target.name }
        }
        try await store.setMailboxNames(names, account: account.id)
        // サイドバーに出す、自分で作ったラベル (Gmail だけ)
        try await store.setLabels(
            account.provider == .gmail ? Self.gmailLabels(in: mailboxes) : [], account: account.id
        )
        var report = Report()
        for target in targets {
            let result = try await sync(target, account: account, session: session)
            report.added += result.added
            report.updated += result.updated
            report.removed += result.removed
        }
        // 受信トレイの未読数はサーバーに聞く (保存しているのは最近の分だけなので、数えると古い未読が漏れる)。
        // Gmail も INBOX を STATUS で聞ける。聞けなくても同期は失敗にしない (保存分で数える)
        if let inbox = mailboxes.first(where: { $0.isSelectable && $0.rawName.uppercased() == "INBOX" }),
           let unread = try? await session.unreadCount(of: inbox.rawName) {
            try await store.setInboxUnreadCount(unread, account: account.id)
        }
        return report
    }

    // MARK: - 1 つのフォルダ

    private func sync(_ target: Target, account: Account, session: some MailServerSession) async throws -> Report {
        let gmail = account.provider == .gmail
        let status = try await session.examine(target.name)
        var report = Report()
        var highest: UInt32

        if let state = try await store.syncState(account: account.id, mailbox: target.name),
           state.uidValidity == status.uidValidity {
            highest = state.highestUID
            // 取得済みのメール: フラグとラベルを取り直し、消えたものを削除する
            let known = try await store.messages(account: account.id, mailbox: target.name)
            if let lowest = known.map(\.uid).min(), lowest <= highest {
                let refreshed = try await session.fetchFlags(
                    in: target.name, uids: lowest...highest, includeGmailAttributes: gmail
                )
                let byUID = Dictionary(refreshed.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
                var changed: [StoredMessage] = []
                var gone: Set<UInt32> = []
                for message in known {
                    guard let fresh = byUID[message.uid] else {
                        gone.insert(message.uid)
                        continue
                    }
                    let updated = Self.applying(fresh, to: message, target: target, gmail: gmail)
                    if updated != message { changed.append(updated) }
                }
                try await store.upsert(changed)
                try await store.delete(account: account.id, mailbox: target.name, uids: gone)
                report.updated = changed.count
                report.removed = gone.count
            }
            // 新しいメール。`n:*` は該当がなくても最後の 1 通を返すので、取得済みの UID は捨てる
            let fresh = try await session.fetchHeaders(
                in: target.name, fromUID: highest + 1, includeGmailAttributes: gmail
            ).filter { $0.uid > highest }
            try await store.upsert(fresh.map {
                Self.makeMessage($0, account: account.id, target: target, uidValidity: status.uidValidity, gmail: gmail)
            })
            report.added = fresh.count
            highest = max(highest, fresh.map(\.uid).max() ?? 0)
        } else {
            // 初回、または UIDVALIDITY が変わった: 保存分を捨てて、最近の分だけ取り直す
            try await store.deleteAll(account: account.id, mailbox: target.name)
            let since = now().addingTimeInterval(-initialWindow)
            let uids = try await session.searchUIDs(in: target.name, since: since, calendar: calendar)
            let headers = try await session.fetchHeaders(in: target.name, uids: uids, includeGmailAttributes: gmail)
            try await store.upsert(headers.map {
                Self.makeMessage($0, account: account.id, target: target, uidValidity: status.uidValidity, gmail: gmail)
            })
            report.added = headers.count
            // 期間内にメールがなくても、次回にフォルダ全体を取りに行かないよう、UIDNEXT の手前を覚えておく
            highest = max(uids.max() ?? 0, (status.uidNext ?? 1) &- 1)
        }

        try await store.setSyncState(
            MailboxSyncState(uidValidity: status.uidValidity, highestUID: highest),
            account: account.id,
            mailbox: target.name
        )
        return report
    }

    // MARK: - 同期するフォルダを選ぶ

    /// SPECIAL-USE がないサーバー向けに、よくある名前から役割を推し量る (小文字で比べる)。
    private static let knownNames: [(MailboxRole, [String])] = [
        (.sent, ["sent", "sent mail", "sent messages", "sent items", "送信済み", "送信済みメール"]),
        (.drafts, ["drafts", "draft", "下書き"]),
        (.archive, ["archive", "archives", "アーカイブ"]),
        (.junk, ["junk", "spam", "bulk mail", "junk e-mail", "迷惑メール"]),
        (.trash, ["trash", "deleted", "deleted messages", "deleted items", "ゴミ箱", "ごみ箱"]),
    ]

    public static func targets(for provider: MailProvider, mailboxes: [IMAPMailbox]) -> [Target] {
        let selectable = mailboxes.filter(\.isSelectable)
        if provider == .gmail, let all = selectable.first(where: { $0.specialUse == .all }) {
            var targets = [Target(name: all.rawName, role: nil)]
            if let junk = selectable.first(where: { $0.specialUse == .junk }) {
                targets.append(Target(name: junk.rawName, role: .junk))
            }
            if let trash = selectable.first(where: { $0.specialUse == .trash }) {
                targets.append(Target(name: trash.rawName, role: .trash))
            }
            return targets
        }

        var targets: [Target] = []
        var usedNames: Set<String> = []
        func add(_ mailbox: IMAPMailbox?, _ role: MailboxRole) {
            guard let mailbox, !usedNames.contains(mailbox.rawName) else { return }
            targets.append(Target(name: mailbox.rawName, role: role))
            usedNames.insert(mailbox.rawName)
        }

        add(selectable.first { $0.rawName.uppercased() == "INBOX" }, .inbox)
        let specialUses: [(IMAPSpecialUse, MailboxRole)] = [
            (.sent, .sent), (.drafts, .drafts), (.archive, .archive), (.junk, .junk), (.trash, .trash),
        ]
        for (use, role) in specialUses {
            let bySpecialUse = selectable.first { $0.specialUse == use }
            let byName = knownNames.first { $0.0 == role }.flatMap { _, names in
                selectable.first { names.contains($0.name.lowercased()) && $0.specialUse == nil }
            }
            add(bySpecialUse ?? byName, role)
        }
        return targets
    }

    /// Gmail の自分で作ったラベル (名前順)。Gmail ではラベルがフォルダとして見えるので、そこから選ぶ。
    /// 受信トレイ、システムのフォルダ (`[Gmail]/...`。英国・ドイツなどでは `[Google Mail]/...`)、
    /// 役割の決まったフォルダ、入れ物だけのフォルダは入れない。
    /// 名前は修正 UTF-7 を解いたもので、メールの `X-GM-LABELS` の名前と同じになる。
    public static func gmailLabels(in mailboxes: [IMAPMailbox]) -> [String] {
        let systemPrefixes = ["[Gmail]", "[Google Mail]"]
        return mailboxes
            .filter { mailbox in
                mailbox.isSelectable
                    && mailbox.specialUse == nil
                    && mailbox.rawName.uppercased() != "INBOX"
                    && !systemPrefixes.contains { mailbox.name == $0 || mailbox.name.hasPrefix($0 + "/") }
            }
            .map(\.name)
            // 大文字・小文字は区別せずに並べる (Linux でも同じ順になるよう、言語ごとの並べ方は使わない)
            .sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
    }

    // MARK: - 見出しから保存用の形へ

    static func makeMessage(
        _ header: IMAPFetchedHeader, account: AccountID, target: Target, uidValidity: UInt32, gmail: Bool
    ) -> StoredMessage {
        let parsed = try? MIMEParser.parse(header.headerData)
        let from = parsed?.from.first
        let contentType = parsed?.headers["Content-Type"]?.lowercased() ?? ""
        let summary = MessageSummary(
            id: MessageID("\(account.rawValue)|\(target.name)|\(uidValidity)|\(header.uid)"),
            accountID: account,
            mailbox: role(for: header, target: target),
            sender: Contact(name: from?.name ?? "", address: from?.address ?? ""),
            recipients: ((parsed?.to ?? []) + (parsed?.cc ?? [])).map { Contact(name: $0.name, address: $0.address) },
            subject: parsed?.subject ?? "",
            preview: "",
            date: parsed?.date ?? Date(timeIntervalSince1970: 0),
            isRead: hasFlag(header.flags, "\\Seen"),
            isStarred: hasFlag(header.flags, "\\Flagged"),
            isFlagged: hasFlag(header.flags, "\\Flagged"),
            hasAttachments: contentType.hasPrefix("multipart/mixed")
        )
        return StoredMessage(
            summary: summary,
            mailbox: target.name,
            uid: header.uid,
            gmailMessageID: header.gmailMessageID,
            gmailThreadID: header.gmailThreadID,
            labels: header.gmailLabels
        )
    }

    /// 取り直したフラグとラベルを反映する。見出しの中身 (件名など) は変わらない。
    static func applying(_ fresh: IMAPFetchedHeader, to message: StoredMessage, target: Target, gmail: Bool) -> StoredMessage {
        var updated = message
        updated.summary.isRead = hasFlag(fresh.flags, "\\Seen")
        updated.summary.isStarred = hasFlag(fresh.flags, "\\Flagged")
        updated.summary.isFlagged = hasFlag(fresh.flags, "\\Flagged")
        if gmail {
            updated.labels = fresh.gmailLabels
            updated.summary.mailbox = role(for: fresh, target: target)
        }
        return updated
    }

    /// Gmail の「すべてのメール」では、ラベルで役割を決める (下書き > 受信トレイ > 送信済み > アーカイブ)。
    static func role(for header: IMAPFetchedHeader, target: Target) -> MailboxRole {
        if let role = target.role { return role }
        if hasFlag(header.gmailLabels, "\\Draft") { return .drafts }
        if hasFlag(header.gmailLabels, "\\Inbox") { return .inbox }
        if hasFlag(header.gmailLabels, "\\Sent") { return .sent }
        return .archive
    }

    private static func hasFlag(_ flags: [String], _ flag: String) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
}
