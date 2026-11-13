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

public struct Account: Identifiable, Hashable, Sendable {
    public let id: AccountID
    public var provider: MailProvider
    public var emailAddress: String
    public var displayName: String

    public init(id: AccountID, provider: MailProvider, emailAddress: String, displayName: String) {
        self.id = id
        self.provider = provider
        self.emailAddress = emailAddress
        self.displayName = displayName
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

public struct Contact: Hashable, Sendable {
    public var name: String
    public var address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// 一覧の 1 行に必要な情報。本文は含まない。
public struct MessageSummary: Identifiable, Hashable, Sendable {
    public let id: MessageID
    public var accountID: AccountID
    public var mailbox: MailboxRole
    public var sender: Contact
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
        self.subject = subject
        self.preview = preview
        self.date = date
        self.isRead = isRead
        self.isStarred = isStarred
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
    }
}

public struct Attachment: Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var byteCount: Int64

    public init(filename: String, mimeType: String, byteCount: Int64) {
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
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
