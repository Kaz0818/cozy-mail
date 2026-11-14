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

    // MARK: - サーバーの写しを消せなかったもの (T23b)

    /// 下書きとは別のファイル (拡張子が json ではないので、下書きの一覧には出ない)。
    private var removalsURL: URL {
        directory.appendingPathComponent("server-removals.list")
    }

    /// まだ消せていないサーバーの写し。古い順。
    public func pendingRemovals() -> [PendingServerRemoval] {
        guard let data = try? Data(contentsOf: removalsURL) else { return [] }
        return (try? JSONDecoder().decode([PendingServerRemoval].self, from: data)) ?? []
    }

    /// 消せなかった写しを覚える (同じものは 1 つだけ)。
    public func addPendingRemoval(_ id: UUID, accountID: AccountID) throws {
        var list = pendingRemovals()
        guard !list.contains(where: { $0.id == id && $0.accountID == accountID }) else { return }
        list.append(PendingServerRemoval(id: id, accountID: accountID))
        try updatePendingRemovals(list)
    }

    /// 覚えている一覧をまるごと書き換える (消せたものを外す、試した回数を増やす)。
    public func updatePendingRemovals(_ list: [PendingServerRemoval]) throws {
        if list.isEmpty {
            if FileManager.default.fileExists(atPath: removalsURL.path) {
                try FileManager.default.removeItem(at: removalsURL)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: removalsURL, options: .atomic)
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

/// サーバーの下書きフォルダから、まだ消せていない写し (T23b)。あとで消し直す。
public struct PendingServerRemoval: Codable, Equatable, Sendable {
    public var id: UUID
    public var accountID: AccountID
    /// 消し直した回数。
    public var attempts: Int

    public init(id: UUID, accountID: AccountID, attempts: Int = 0) {
        self.id = id
        self.accountID = accountID
        self.attempts = attempts
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
    /// Mac の下書きを一覧から消したあとに呼ぶ (サーバーの写しも消すため、T23b)。
    private let onDelete: @Sendable (SavedDraft) async -> Void

    public init(
        base: any MailRepository, drafts: DraftStore,
        onDelete: @escaping @Sendable (SavedDraft) async -> Void = { _ in }
    ) {
        self.base = base
        self.drafts = drafts
        self.onDelete = onDelete
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
        // サーバーに置いた写し (T23b) が同期で戻ってきたものは出さない (Mac の下書きを出す)。
        // 同じアカウント・同じ件名で、日付が保存した時刻とほぼ同じもの (見出しの日付は秒までなので、少し幅を持たせる)
        let remote = messages.filter { message in
            !local.contains { draft in
                draft.accountID == message.accountID && draft.subject == message.subject
                    && abs(draft.date.timeIntervalSince(message.date)) < 2
            }
        }
        return (local + remote).sorted { $0.date > $1.date }
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

    public func searchServer(_ text: String) async throws -> [MessageSummary] {
        try await base.searchServer(text)
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
        let saved = await drafts.draft(draftID)
        try await drafts.delete(draftID)
        if let saved { await onDelete(saved) }
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
