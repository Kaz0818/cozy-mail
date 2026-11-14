import Foundation

/// 作成ウィンドウの中身 (T23a)。宛先は打った文字のまま持つ (読めない宛先があっても、書いたものを失わないため)。
public struct DraftContent: Sendable, Equatable {
    public var accountID: AccountID?
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var body: String
    public var attachments: [DraftAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var quote: String

    public init(
        accountID: AccountID? = nil, to: String = "", cc: String = "", bcc: String = "",
        subject: String = "", body: String = "", attachments: [DraftAttachment] = [],
        inReplyTo: String? = nil, references: [String] = [], quote: String = ""
    ) {
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.quote = quote
    }

    /// 送る形 (読めない宛先は除く)。
    public var draft: Draft {
        Draft(
            accountID: accountID,
            to: Composer.parseRecipients(to).contacts,
            cc: Composer.parseRecipients(cc).contacts,
            bcc: Composer.parseRecipients(bcc).contacts,
            subject: subject, body: body, attachments: attachments,
            inReplyTo: inReplyTo, references: references, quote: quote
        )
    }
}

/// Mac に保存した下書き。
public struct SavedDraft: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var content: DraftContent
    public var savedAt: Date
}

/// 下書きを Mac に保存する (T23a、US-14)。下書き 1 つを 1 つの JSON ファイルにする。
/// SwiftData のモデル (保存データの形) は変えない。
public actor DraftStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ content: DraftContent, id: UUID, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(FileFormat(id: id, savedAt: date, content: content))
        // 書いている途中で落ちても、前の中身が壊れないように
        try data.write(to: url(for: id), options: .atomic)
    }

    public func draft(_ id: UUID) -> SavedDraft? {
        read(url(for: id))
    }

    /// すべての下書き。新しく保存した順。読めないファイルは飛ばす。
    public func all() -> [SavedDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap(read)
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func read(_ url: URL) -> SavedDraft? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else { return nil }
        return SavedDraft(id: file.id, content: file.content.content, savedAt: file.savedAt)
    }

    // MARK: - ファイルの形 (版 1)

    private struct FileFormat: Codable {
        var version = 1
        var id: UUID
        var savedAt: Date
        var content: StoredContent

        init(id: UUID, savedAt: Date, content: DraftContent) {
            self.id = id
            self.savedAt = savedAt
            self.content = StoredContent(content)
        }
    }

    private struct StoredAttachment: Codable {
        var id: UUID
        var filename: String
        var mimeType: String
        var data: Data
    }

    private struct StoredContent: Codable {
        var accountID: String?
        var to: String
        var cc: String
        var bcc: String
        var subject: String
        var body: String
        var attachments: [StoredAttachment]
        var inReplyTo: String?
        var references: [String]
        var quote: String

        init(_ content: DraftContent) {
            accountID = content.accountID?.rawValue
            to = content.to
            cc = content.cc
            bcc = content.bcc
            subject = content.subject
            body = content.body
            attachments = content.attachments.map {
                StoredAttachment(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
            inReplyTo = content.inReplyTo
            references = content.references
            quote = content.quote
        }

        var content: DraftContent {
            DraftContent(
                accountID: accountID.map(AccountID.init), to: to, cc: cc, bcc: bcc, subject: subject, body: body,
                attachments: attachments.map { DraftAttachment(id: $0.id, filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
                inReplyTo: inReplyTo, references: references, quote: quote
            )
        }
    }
}

/// Mac に保存した下書きを、一覧の 1 通として表すための番号。
public enum LocalDraft {
    private static let prefix = "local-draft/"

    public static func messageID(_ id: UUID) -> MessageID {
        MessageID(prefix + id.uuidString)
    }

    /// Mac の下書きなら、その番号。サーバーのメールなら nil。
    public static func id(from messageID: MessageID) -> UUID? {
        guard messageID.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(messageID.rawValue.dropFirst(prefix.count)))
    }
}

/// 下書きフォルダに、Mac に保存した下書きも出す窓口 (T23a)。ほかはもとの窓口にそのまま頼む。
public struct DraftsMergingRepository: MailRepository {
    private let base: any MailRepository
    private let drafts: DraftStore

    public init(base: any MailRepository, drafts: DraftStore) {
        self.base = base
        self.drafts = drafts
    }

    public func accounts() async throws -> [Account] {
        try await base.accounts()
    }

    public func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        let messages = try await base.messages(in: selection, filter: filter)
        // 下書きは既読でスターなし。「未読」「スター付き」で絞っているときは出さない
        guard selection.role == .drafts, filter == .all else { return messages }
        let fallback = try? await base.accounts().first?.id
        let local = await drafts.all().compactMap { saved -> MessageSummary? in
            guard let accountID = saved.content.accountID ?? fallback else { return nil }
            if let wanted = selection.accountID, wanted != accountID { return nil }
            return Self.summary(saved, accountID: accountID)
        }
        return (local + messages).sorted { $0.date > $1.date }
    }

    public func unreadCount(in selection: MailboxSelection) async throws -> Int {
        try await base.unreadCount(in: selection)
    }

    public func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary] {
        try await base.search(text, filter: filter)
    }

    public func labels(for account: AccountID) async throws -> [String] {
        try await base.labels(for: account)
    }

    public func body(for id: MessageID) async throws -> MessageBody {
        guard let draftID = LocalDraft.id(from: id) else { return try await base.body(for: id) }
        guard let saved = await drafts.draft(draftID) else { throw MailRepositoryError.messageNotFound(id) }
        let draft = saved.content.draft
        return MessageBody(
            messageID: id, to: draft.to, cc: draft.cc, text: saved.content.body,
            attachments: draft.attachments.enumerated().map { index, attachment in
                Attachment(filename: attachment.filename, mimeType: attachment.mimeType,
                           byteCount: Int64(attachment.data.count), index: index)
            }
        )
    }

    public func attachmentData(for id: MessageID, index: Int) async throws -> Data {
        guard let draftID = LocalDraft.id(from: id) else { return try await base.attachmentData(for: id, index: index) }
        guard let attachments = await drafts.draft(draftID)?.content.attachments, attachments.indices.contains(index) else {
            throw MailRepositoryError.attachmentNotFound
        }
        return attachments[index].data
    }

    /// Mac の下書きは「削除」だけできる (消す)。ほかの操作はできない。
    public func perform(_ action: MessageAction, on id: MessageID) async throws {
        guard let draftID = LocalDraft.id(from: id) else { return try await base.perform(action, on: id) }
        guard action == .moveToTrash else { throw MailRepositoryError.actionNotApplicable }
        try await drafts.delete(draftID)
    }

    public func perform(_ action: MessageAction, on ids: [MessageID]) async throws {
        let local = ids.filter { LocalDraft.id(from: $0) != nil }
        let remote = ids.filter { LocalDraft.id(from: $0) == nil }
        var firstError: (any Error)?
        if !remote.isEmpty {
            do { try await base.perform(action, on: remote) } catch { firstError = error }
        }
        for id in local {
            do {
                try await perform(action, on: id)
            } catch MailRepositoryError.actionNotApplicable where ids.count > 1 {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    public func replySource(for id: MessageID) async throws -> ReplySource {
        try await base.replySource(for: id)
    }

    public func send(_ draft: Draft) async throws -> SendOutcome {
        try await base.send(draft)
    }

    private static func summary(_ saved: SavedDraft, accountID: AccountID) -> MessageSummary {
        let draft = saved.content.draft
        let firstLine = saved.content.body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return MessageSummary(
            id: LocalDraft.messageID(saved.id), accountID: accountID, mailbox: .drafts,
            // 下書きの一覧では、差出人の欄に宛先を出す (Mail.app と同じ)
            sender: draft.to.first ?? Contact(name: "", address: ""),
            recipients: draft.to + draft.cc,
            subject: saved.content.subject, preview: firstLine, date: saved.savedAt,
            isRead: true, hasAttachments: !draft.attachments.isEmpty
        )
    }
}
