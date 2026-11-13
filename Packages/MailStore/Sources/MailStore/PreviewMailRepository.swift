import Foundation

/// 見本の画像と同じ内容を返す仮データ。画面の確認 (v0.0) と SwiftUI プレビューに使う。
public struct PreviewMailRepository: MailRepository {
    private let accountList: [Account]
    private let summaries: [MessageSummary]
    private let bodies: [MessageID: MessageBody]

    public init(now: Date = Date(), calendar: Calendar = .current) {
        let data = PreviewData(now: now, calendar: calendar)
        accountList = data.accounts
        summaries = data.messages.sorted { $0.date > $1.date }
        bodies = data.bodies
    }

    public func accounts() async throws -> [Account] {
        accountList
    }

    public func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        summaries.filter { selection.contains($0) && filter.matches($0) }
    }

    public func unreadCount(in selection: MailboxSelection) async throws -> Int {
        summaries.count { selection.contains($0) && !$0.isRead }
    }

    public func body(for id: MessageID) async throws -> MessageBody {
        if let body = bodies[id] { return body }
        guard let summary = summaries.first(where: { $0.id == id }) else {
            throw MailRepositoryError.messageNotFound(id)
        }
        return MessageBody(messageID: id, to: [Contact(name: "自分", address: "me@example.com")], text: summary.preview)
    }

    /// 見本のメールは変えられない。
    public func perform(_ action: MessageAction, on id: MessageID) async throws {
        throw MailRepositoryError.actionUnavailable
    }

    /// 見本のメールにも返信・転送の画面は開ける (送ることはできない)。
    public func replySource(for id: MessageID) async throws -> ReplySource {
        guard let summary = summaries.first(where: { $0.id == id }) else { throw MailRepositoryError.messageNotFound(id) }
        let body = try await body(for: id)
        return ReplySource(
            accountID: summary.accountID,
            from: [summary.sender],
            to: body.to,
            cc: body.cc,
            subject: summary.subject,
            date: summary.date,
            messageID: "\(id.rawValue)@preview.cozymail",
            text: body.text
        )
    }

    /// 見本なので送れない。
    public func send(_ draft: Draft) async throws -> SendOutcome {
        throw MailRepositoryError.actionUnavailable
    }

    /// 見本なので、添付ファイルの中身は説明の文だけ。
    public func attachmentData(for id: MessageID, index: Int) async throws -> Data {
        guard let attachment = bodies[id]?.attachments.first(where: { $0.index == index }) else {
            throw MailRepositoryError.attachmentNotFound
        }
        return Data("これは見本の添付ファイル「\(attachment.filename)」です。".utf8)
    }
}

/// 仮データの中身。件数は見本の未読数 (仕事 12、プライベート 3、副業 0、Yahoo! 7、合計 22) に合わせてある。
private final class PreviewData {
    let accounts: [Account]
    var messages: [MessageSummary] = []
    var bodies: [MessageID: MessageBody] = [:]

    private let now: Date
    private let calendar: Calendar
    private var nextID = 0

    init(now: Date, calendar: Calendar) {
        self.now = now
        self.calendar = calendar
        let work = Account(id: AccountID("work"), provider: .gmail, emailAddress: "work@example.com", displayName: "Gmail (仕事)")
        let personal = Account(
            id: AccountID("personal"), provider: .gmail, emailAddress: "personal@example.com",
            displayName: "Gmail (プライベート)"
        )
        let side = Account(id: AccountID("side"), provider: .gmail, emailAddress: "side@example.com", displayName: "Gmail (副業)")
        let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!メール")
        accounts = [work, personal, side, yahoo]

        addFeatured(work: work.id, personal: personal.id, yahoo: yahoo.id)
        addFillers(account: work.id, unread: 9, read: 4, starredEvery: 3)
        addFillers(account: personal.id, unread: 2, read: 3, starredEvery: 0)
        addFillers(account: side.id, unread: 0, read: 3, starredEvery: 2)
        addFillers(account: yahoo.id, unread: 6, read: 2, starredEvery: 0)
        addDrafts(account: work.id)
    }

    // MARK: - 見本に写っている 6 通

    private func addFeatured(work: AccountID, personal: AccountID, yahoo: AccountID) {
        let proposal = add(
            account: work, sender: Contact(name: "山田 さくら", address: "s.yamada@example.com"),
            subject: "企画のご提案について", preview: "先日の打ち合わせをもとに、企画書を作成しました。",
            date: today(16, 24), hasAttachments: true
        )
        bodies[proposal] = MessageBody(
            messageID: proposal,
            to: [Contact(name: "自分", address: "work@example.com")],
            text: """
            お疲れさまです。
            先日の打ち合わせをもとに、企画書を作成しました。

            添付の資料をご確認いただき、
            ご意見をいただけますでしょうか。

            よろしくお願いいたします。

            --
            山田 さくら
            株式会社サンプル
            企画部
            """,
            attachments: [Attachment(filename: "企画書（Ver.2）.pdf", mimeType: "application/pdf", byteCount: 4_800_000)]
        )
        add(
            account: personal, sender: Contact(name: "Google", address: "no-reply@accounts.google.com"),
            subject: "セキュリティ通知", preview: "新しいデバイスからのログインがありました。心当たりがない場合は…",
            date: today(15, 37), isRead: true
        )
        add(
            account: work, sender: Contact(name: "田中 健一", address: "k.tanaka@example.com"),
            subject: "打ち合わせの日程調整", preview: "来週のミーティングについて、候補日をいくつかお送りします。",
            date: today(14, 5)
        )
        add(
            account: yahoo, sender: Contact(name: "Yahoo!ショッピング", address: "shopping@mail.yahoo.example"),
            subject: "ご注文の確認", preview: "ご注文ありがとうございます。注文内容をお知らせします。",
            date: today(12, 48)
        )
        add(
            account: personal, sender: Contact(name: "Apple", address: "no_reply@email.apple.example"),
            subject: "Apple ID のお知らせ", preview: "ご利用の Apple ID に関する重要なお知らせです。",
            date: today(11, 20)
        )
        add(
            account: work, sender: Contact(name: "プロジェクトチーム", address: "project-team@example.com"),
            subject: "週次レポートの共有", preview: "今週の進捗レポートを共有します。ご確認ください。",
            date: today(10, 2)
        )
    }

    // MARK: - 件数合わせの古いメール

    private static let fillerSenders = [
        Contact(name: "佐藤 美咲", address: "m.sato@example.com"),
        Contact(name: "経理部", address: "keiri@example.com"),
        Contact(name: "Amazon.co.jp", address: "order@amazon.example"),
        Contact(name: "鈴木 大輔", address: "d.suzuki@example.com"),
        Contact(name: "GitHub", address: "noreply@github.example"),
        Contact(name: "楽天トラベル", address: "travel@rakuten.example"),
        Contact(name: "高橋 由美", address: "y.takahashi@example.com"),
        Contact(name: "Slack", address: "feedback@slack.example"),
    ]

    private static let fillerSubjects = [
        ("来月のスケジュールについて", "来月の予定を共有します。変更があればお知らせください。"),
        ("請求書送付のご案内", "今月分の請求書をお送りします。期日までにお支払いをお願いします。"),
        ("商品を発送しました", "ご注文の商品を発送しました。お届け予定日は…"),
        ("資料のご確認のお願い", "添付の資料について、ご意見をいただけますでしょうか。"),
        ("週間ダイジェスト", "今週の新着情報をまとめてお届けします。"),
        ("ご予約の確認", "ご予約ありがとうございます。宿泊内容は以下のとおりです。"),
        ("Re: 先日の件", "ご連絡ありがとうございます。承知しました。"),
        ("新しいメッセージがあります", "未読のメッセージが 3 件あります。"),
    ]

    private func addFillers(account: AccountID, unread: Int, read: Int, starredEvery: Int) {
        for index in 0..<(unread + read) {
            let pick = (nextID + index) % Self.fillerSenders.count
            let (subject, preview) = Self.fillerSubjects[pick]
            add(
                account: account, sender: Self.fillerSenders[pick], subject: subject, preview: preview,
                date: daysAgo(1 + index, hour: 18 - index % 9),
                isRead: index >= unread,
                isStarred: starredEvery > 0 && index % starredEvery == 0 && index >= unread
            )
        }
    }

    private func addDrafts(account: AccountID) {
        let me = Contact(name: "自分", address: "work@example.com")
        add(account: account, mailbox: .drafts, sender: me, subject: "Re: 企画のご提案について",
            preview: "山田さん、資料ありがとうございます。", date: today(9, 30), isRead: true)
        add(account: account, mailbox: .drafts, sender: me, subject: "来週の出張について",
            preview: "（下書き）", date: daysAgo(2, hour: 20), isRead: true)
    }

    // MARK: - 部品

    @discardableResult
    private func add(
        account: AccountID,
        mailbox: MailboxRole = .inbox,
        sender: Contact,
        subject: String,
        preview: String,
        date: Date,
        isRead: Bool = false,
        isStarred: Bool = false,
        hasAttachments: Bool = false
    ) -> MessageID {
        nextID += 1
        let id = MessageID("preview-\(nextID)")
        messages.append(MessageSummary(
            id: id, accountID: account, mailbox: mailbox, sender: sender, subject: subject, preview: preview,
            date: date, isRead: isRead, isStarred: isStarred, hasAttachments: hasAttachments
        ))
        return id
    }

    private func today(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }

    private func daysAgo(_ days: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}
