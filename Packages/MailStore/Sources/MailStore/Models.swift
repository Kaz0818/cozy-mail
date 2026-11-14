import Foundation

/// アカウントを一意に表す ID。
public struct AccountID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// メールを一意に表す ID (アプリ内の ID。IMAP の UID とは別)。
public struct MessageID: Hashable, Sendable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// メールの事業者。サーバー設定の自動入力やアイコンに使う。
public enum MailProvider: String, Sendable, Codable, CaseIterable {
    case gmail
    case yahoo
    case icloud
    case outlook
    case other
}

public struct Account: Identifiable, Hashable, Sendable, Codable {
    public let id: AccountID
    public var provider: MailProvider
    public var emailAddress: String
    /// 設定の画面で見分けるための名前 (例: 「Gmail (仕事)」)。相手には見えない。
    public var displayName: String
    /// 送ったメールの差出人として相手に見える名前 (例: 「山田 太郎」)。空なら、アドレスだけで送る。
    /// 前の版で保存したアカウントにはこの項目がないので、読み込むときは空になる。
    public var senderName: String

    public init(id: AccountID, provider: MailProvider, emailAddress: String, displayName: String, senderName: String = "") {
        self.id = id
        self.provider = provider
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.senderName = senderName
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, emailAddress, displayName, senderName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(AccountID.self, forKey: .id)
        provider = try container.decode(MailProvider.self, forKey: .provider)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        displayName = try container.decode(String.self, forKey: .displayName)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? ""
    }
}

/// フォルダの役割。`starred` と `unread` は、全フォルダを横断する仮想フォルダ。
public enum MailboxRole: String, Sendable, Codable, CaseIterable {
    case inbox
    case starred
    case unread
    case sent
    case drafts
    case archive
    case junk
    case trash

    /// 実際のフォルダではなく、条件で絞り込んだ一覧かどうか。
    public var isVirtual: Bool {
        self == .starred || self == .unread
    }
}

/// サイドバーで選んでいるもの。
public enum MailboxSelection: Hashable, Sendable {
    /// 全アカウントをまとめたフォルダ (統合受信トレイなど)。
    case unified(MailboxRole)
    /// 1 つのアカウントのフォルダ。
    case account(AccountID, MailboxRole)

    public var role: MailboxRole {
        switch self {
        case let .unified(role), let .account(_, role): role
        }
    }

    public var accountID: AccountID? {
        switch self {
        case .unified: nil
        case let .account(id, _): id
        }
    }
}

/// 一覧の上の絞り込みタブ。
public enum MessageFilter: String, Sendable, CaseIterable {
    case all
    case unread
    case starred
}

public struct Contact: Hashable, Sendable, Codable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// 画面に出す名前。名前がないメールは、アドレスを出す (空の名前で「?」のアイコンにならないように)。
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? address : trimmed
    }
}

/// 一覧の 1 行に必要な情報。本文は含まない。
public struct MessageSummary: Identifiable, Hashable, Sendable, Codable {
    public let id: MessageID
    public var accountID: AccountID
    public var mailbox: MailboxRole
    public var sender: Contact
    /// 宛先 (To と Cc)。「送信済み」と「下書き」の一覧では、差出人 (自分) の代わりにこれを出す。
    public var recipients: [Contact]
    public var subject: String
    public var preview: String
    public var date: Date
    public var isRead: Bool
    public var isStarred: Bool
    public var isFlagged: Bool
    public var hasAttachments: Bool

    public init(
        id: MessageID,
        accountID: AccountID,
        mailbox: MailboxRole,
        sender: Contact,
        recipients: [Contact] = [],
        subject: String,
        preview: String,
        date: Date,
        isRead: Bool = false,
        isStarred: Bool = false,
        isFlagged: Bool = false,
        hasAttachments: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.mailbox = mailbox
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.preview = preview
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
    }
}

extension MessageSummary {
    /// 自分が送った (送る) メールか。「送信済み」と「下書き」。
    public var isOutgoing: Bool {
        mailbox == .sent || mailbox == .drafts
    }

    /// 一覧の行に出す相手。ふつうは差出人、自分が送ったメールは宛先 (なければ差出人)。
    public var listContacts: [Contact] {
        isOutgoing && !recipients.isEmpty ? recipients : [sender]
    }

    /// 一覧の行に出す名前。自分が送ったメールは「宛先: 田中 健一、佐藤」のようにする。
    public var listTitle: String {
        let names = listContacts.map(\.displayName).joined(separator: "、")
        return isOutgoing && !recipients.isEmpty ? "宛先: \(names)" : names
    }
}

public struct Attachment: Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var byteCount: Int64
    /// メールの中で何番目の添付か。中身を取り出すとき (`MailRepository.attachmentData`) に使う。
    public var index: Int

    public init(filename: String, mimeType: String, byteCount: Int64, index: Int = 0) {
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.index = index
    }
}

/// メールを開いたときに表示する中身。
public struct MessageBody: Hashable, Sendable {
    public var messageID: MessageID
    public var to: [Contact]
    public var cc: [Contact]
    public var text: String
    public var html: String?
    public var attachments: [Attachment]

    public init(
        messageID: MessageID,
        to: [Contact],
        cc: [Contact] = [],
        text: String,
        html: String? = nil,
        attachments: [Attachment] = []
    ) {
        self.messageID = messageID
        self.to = to
        self.cc = cc
        self.text = text
        self.html = html
        self.attachments = attachments
    }
}
