#if canImport(SwiftData)
import Foundation
import MailStore
import SwiftData

/// SwiftData に保存するモデルの第 1 版。形を変えるときは `MailSchemaV2` を足し、`MailMigrationPlan` に移行の手順を書く
/// (保存済みのメールを捨てずに済ませるため。SPEC 9 章「先に相談する」)。
enum MailSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [MailRecord.self, RawMessageRecord.self, SyncStateRecord.self, AccountRecord.self] }

    /// メール 1 通の見出しと、サーバーと突き合わせるための情報。本文の生データは別の `RawMessageRecord` に置く
    /// (一覧のために何年分も読み込んでも、本文は読まないで済むように)。
    @Model final class MailRecord {
        // フォルダごとの一覧・UID での検索・日付順の取り出しが、メールが増えても遅くならないための索引
        #Index<MailRecord>([\.accountID, \.mailbox, \.uid], [\.accountID, \.mailbox], [\.date])

        @Attribute(.unique) var key: String
        var accountID: String
        var mailbox: String
        /// UInt32 の UID。
        var uid: Int64
        var role: String
        var senderName: String
        var senderAddress: String
        /// 宛先 (`[ContactRecord]` を JSON にしたもの)。
        var recipients: Data
        var subject: String
        var preview: String
        var date: Date
        var isRead: Bool
        var isStarred: Bool
        var isFlagged: Bool
        var hasAttachments: Bool
        /// Gmail の ID は UInt64。ビットをそのまま Int64 に入れる (大きい値も欠けない)。
        var gmailMessageID: Int64?
        var gmailThreadID: Int64?
        var labels: [String]

        init(
            key: String, accountID: String, mailbox: String, uid: Int64, role: String,
            senderName: String, senderAddress: String, recipients: Data, subject: String, preview: String, date: Date,
            isRead: Bool, isStarred: Bool, isFlagged: Bool, hasAttachments: Bool,
            gmailMessageID: Int64?, gmailThreadID: Int64?, labels: [String]
        ) {
            self.key = key
            self.accountID = accountID
            self.mailbox = mailbox
            self.uid = uid
            self.role = role
            self.senderName = senderName
            self.senderAddress = senderAddress
            self.recipients = recipients
            self.subject = subject
            self.preview = preview
            self.date = date
            self.isRead = isRead
            self.isStarred = isStarred
            self.isFlagged = isFlagged
            self.hasAttachments = hasAttachments
            self.gmailMessageID = gmailMessageID
            self.gmailThreadID = gmailThreadID
            self.labels = labels
        }
    }

    /// 取得したメール全体 (本文と添付)。大きいものは SwiftData がデータベースの外のファイルに置く。
    @Model final class RawMessageRecord {
        @Attribute(.unique) var key: String
        @Attribute(.externalStorage) var data: Data

        init(key: String, data: Data) {
            self.key = key
            self.data = data
        }
    }

    /// フォルダごとの同期の進み具合 (`UIDVALIDITY` と取得済みの最大 UID)。
    @Model final class SyncStateRecord {
        @Attribute(.unique) var key: String
        var accountID: String
        var mailbox: String
        var uidValidity: Int64
        var highestUID: Int64

        init(key: String, accountID: String, mailbox: String, uidValidity: Int64, highestUID: Int64) {
            self.key = key
            self.accountID = accountID
            self.mailbox = mailbox
            self.uidValidity = uidValidity
            self.highestUID = highestUID
        }
    }

    /// アカウントごとの小さな情報 (受信トレイの未読数、役割ごとのフォルダ名)。
    @Model final class AccountRecord {
        @Attribute(.unique) var accountID: String
        var inboxUnread: Int?
        /// `[MailboxRole.rawValue: フォルダ名]` を JSON にしたもの。
        var mailboxNames: Data?

        init(accountID: String) {
            self.accountID = accountID
        }
    }
}

typealias MailRecord = MailSchemaV1.MailRecord
typealias RawMessageRecord = MailSchemaV1.RawMessageRecord
typealias SyncStateRecord = MailSchemaV1.SyncStateRecord
typealias AccountRecord = MailSchemaV1.AccountRecord

enum MailMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MailSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

private struct ContactRecord: Codable {
    var name: String
    var address: String
}

/// メールを Mac の中に SwiftData で保存する。アプリを終了しても残り、次の起動ですぐ前回の一覧が出る。
///
/// - 何年分あっても、フォルダごとの取り出しは索引を使う。
/// - 本文 (添付つきの生データ) は見出しとは別に置き、大きいものはデータベースの外のファイルに置く。
/// - 保存先のフォルダは本人だけが読める (0700)。iCloud には同期しない。
@ModelActor
public actor SwiftDataMessageStore: MessageStore {
    /// 保存ファイルの名前。
    public static let fileName = "Mail.store"

    /// 一度に SQL に渡す件数の上限 (`IN` に入れる数が多すぎると失敗するため)。
    private static let chunkSize = 400

    /// `directory` の中に保存ファイルを作る (なければ作り、あれば開く)。開けなければ投げる。
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // 既にあったフォルダの権限も締める
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let configuration = ModelConfiguration(
            schema: Schema(versionedSchema: MailSchemaV1.self),
            url: directory.appendingPathComponent(Self.fileName),
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: Schema(versionedSchema: MailSchemaV1.self),
            migrationPlan: MailMigrationPlan.self,
            configurations: configuration
        )
        self.init(modelContainer: container)
    }

    /// アプリの保存場所 (Application Support の中)。サンドボックスのアプリでは、アプリ専用の領域になる。
    public static func defaultDirectory(appFolder: String = "CozyMail") throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    // MARK: - 同期の進み具合

    public func syncState(account: AccountID, mailbox: String) throws -> MailboxSyncState? {
        let key = Self.folderKey(account, mailbox)
        let record = try fetchOne(FetchDescriptor<SyncStateRecord>(predicate: #Predicate { $0.key == key }))
        return record.map { MailboxSyncState(uidValidity: UInt32(truncatingIfNeeded: $0.uidValidity), highestUID: UInt32(truncatingIfNeeded: $0.highestUID)) }
    }

    public func setSyncState(_ state: MailboxSyncState, account: AccountID, mailbox: String) throws {
        let key = Self.folderKey(account, mailbox)
        if let record = try fetchOne(FetchDescriptor<SyncStateRecord>(predicate: #Predicate { $0.key == key })) {
            record.uidValidity = Int64(state.uidValidity)
            record.highestUID = Int64(state.highestUID)
        } else {
            modelContext.insert(SyncStateRecord(
                key: key, accountID: account.rawValue, mailbox: mailbox,
                uidValidity: Int64(state.uidValidity), highestUID: Int64(state.highestUID)
            ))
        }
        try modelContext.save()
    }

    // MARK: - メール

    public func messages(account: AccountID, mailbox: String) throws -> [StoredMessage] {
        let accountID = account.rawValue
        let records = try modelContext.fetch(FetchDescriptor<MailRecord>(
            predicate: #Predicate { $0.accountID == accountID && $0.mailbox == mailbox }
        ))
        return records.map(Self.stored)
    }

    public func upsert(_ messages: [StoredMessage]) throws {
        for chunk in messages.chunked(Self.chunkSize) {
            let keys = chunk.map(\.summary.id.rawValue)
            let existing = try Dictionary(
                modelContext.fetch(FetchDescriptor<MailRecord>(predicate: #Predicate { keys.contains($0.key) })).map { ($0.key, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for message in chunk {
                if let record = existing[message.summary.id.rawValue] {
                    Self.fill(record, from: message)
                } else {
                    modelContext.insert(Self.record(from: message))
                }
            }
        }
        try modelContext.save()
    }

    public func delete(account: AccountID, mailbox: String, uids: Set<UInt32>) throws {
        let accountID = account.rawValue
        for chunk in uids.sorted().chunked(Self.chunkSize) {
            let uidValues = chunk.map { Int64($0) }
            let records = try modelContext.fetch(FetchDescriptor<MailRecord>(
                predicate: #Predicate { $0.accountID == accountID && $0.mailbox == mailbox && uidValues.contains($0.uid) }
            ))
            try remove(records)
        }
        try modelContext.save()
    }

    public func deleteAll(account: AccountID, mailbox: String) throws {
        let accountID = account.rawValue
        try remove(modelContext.fetch(FetchDescriptor<MailRecord>(
            predicate: #Predicate { $0.accountID == accountID && $0.mailbox == mailbox }
        )))
        let key = Self.folderKey(account, mailbox)
        try modelContext.delete(model: SyncStateRecord.self, where: #Predicate { $0.key == key })
        try modelContext.save()
    }

    public func deleteAccount(_ account: AccountID) throws {
        let accountID = account.rawValue
        try remove(modelContext.fetch(FetchDescriptor<MailRecord>(predicate: #Predicate { $0.accountID == accountID })))
        try modelContext.delete(model: SyncStateRecord.self, where: #Predicate { $0.accountID == accountID })
        try modelContext.delete(model: AccountRecord.self, where: #Predicate { $0.accountID == accountID })
        try modelContext.save()
    }

    public func allSummaries() throws -> [MessageSummary] {
        try modelContext.fetch(FetchDescriptor<MailRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)]))
            .map { Self.stored($0).summary }
    }

    public func message(id: MessageID) throws -> StoredMessage? {
        let key = id.rawValue
        return try fetchOne(FetchDescriptor<MailRecord>(predicate: #Predicate { $0.key == key })).map(Self.stored)
    }

    // MARK: - 本文の生データ

    public func rawMessage(for id: MessageID) throws -> Data? {
        let key = id.rawValue
        return try fetchOne(FetchDescriptor<RawMessageRecord>(predicate: #Predicate { $0.key == key }))?.data
    }

    public func setRawMessage(_ data: Data, for id: MessageID) throws {
        let key = id.rawValue
        if let record = try fetchOne(FetchDescriptor<RawMessageRecord>(predicate: #Predicate { $0.key == key })) {
            record.data = data
        } else {
            modelContext.insert(RawMessageRecord(key: key, data: data))
        }
        try modelContext.save()
    }

    // MARK: - アカウントごとの情報

    public func inboxUnreadCount(account: AccountID) throws -> Int? {
        try accountRecord(account, create: false)?.inboxUnread
    }

    public func setInboxUnreadCount(_ count: Int, account: AccountID) throws {
        try accountRecord(account, create: true)?.inboxUnread = count
        try modelContext.save()
    }

    public func mailboxName(for role: MailboxRole, account: AccountID) throws -> String? {
        guard let data = try accountRecord(account, create: false)?.mailboxNames else { return nil }
        return try JSONDecoder().decode([String: String].self, from: data)[role.rawValue]
    }

    public func setMailboxNames(_ names: [MailboxRole: String], account: AccountID) throws {
        let data = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: names.map { ($0.key.rawValue, $0.value) }))
        try accountRecord(account, create: true)?.mailboxNames = data
        try modelContext.save()
    }

    // MARK: - 補助

    /// メールと、その本文の生データをまとめて消す。
    private func remove(_ records: [MailRecord]) throws {
        for chunk in records.chunked(Self.chunkSize) {
            let keys = chunk.map(\.key)
            try modelContext.delete(model: RawMessageRecord.self, where: #Predicate { keys.contains($0.key) })
        }
        for record in records { modelContext.delete(record) }
    }

    private func accountRecord(_ account: AccountID, create: Bool) throws -> AccountRecord? {
        let accountID = account.rawValue
        if let record = try fetchOne(FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.accountID == accountID })) {
            return record
        }
        guard create else { return nil }
        let record = AccountRecord(accountID: accountID)
        modelContext.insert(record)
        return record
    }

    private func fetchOne<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// アカウントとフォルダ名を 1 つの文字列にする (どちらにも現れない区切り文字を使う)。
    private static func folderKey(_ account: AccountID, _ mailbox: String) -> String {
        "\(account.rawValue)\u{1F}\(mailbox)"
    }

    private static func record(from message: StoredMessage) -> MailRecord {
        let record = MailRecord(
            key: "", accountID: "", mailbox: "", uid: 0, role: "", senderName: "", senderAddress: "", recipients: Data(),
            subject: "", preview: "", date: .distantPast, isRead: false, isStarred: false, isFlagged: false,
            hasAttachments: false, gmailMessageID: nil, gmailThreadID: nil, labels: []
        )
        fill(record, from: message)
        return record
    }

    private static func fill(_ record: MailRecord, from message: StoredMessage) {
        let summary = message.summary
        record.key = summary.id.rawValue
        record.accountID = summary.accountID.rawValue
        record.mailbox = message.mailbox
        record.uid = Int64(message.uid)
        record.role = summary.mailbox.rawValue
        record.senderName = summary.sender.name
        record.senderAddress = summary.sender.address
        record.recipients = (try? JSONEncoder().encode(summary.recipients.map { ContactRecord(name: $0.name, address: $0.address) })) ?? Data()
        record.subject = summary.subject
        record.preview = summary.preview
        record.date = summary.date
        record.isRead = summary.isRead
        record.isStarred = summary.isStarred
        record.isFlagged = summary.isFlagged
        record.hasAttachments = summary.hasAttachments
        record.gmailMessageID = message.gmailMessageID.map { Int64(bitPattern: $0) }
        record.gmailThreadID = message.gmailThreadID.map { Int64(bitPattern: $0) }
        record.labels = message.labels
    }

    private static func stored(_ record: MailRecord) -> StoredMessage {
        let recipients = (try? JSONDecoder().decode([ContactRecord].self, from: record.recipients)) ?? []
        return StoredMessage(
            summary: MessageSummary(
                id: MessageID(record.key),
                accountID: AccountID(record.accountID),
                mailbox: MailboxRole(rawValue: record.role) ?? .inbox,
                sender: Contact(name: record.senderName, address: record.senderAddress),
                recipients: recipients.map { Contact(name: $0.name, address: $0.address) },
                subject: record.subject,
                preview: record.preview,
                date: record.date,
                isRead: record.isRead,
                isStarred: record.isStarred,
                isFlagged: record.isFlagged,
                hasAttachments: record.hasAttachments
            ),
            mailbox: record.mailbox,
            uid: UInt32(truncatingIfNeeded: record.uid),
            gmailMessageID: record.gmailMessageID.map { UInt64(bitPattern: $0) },
            gmailThreadID: record.gmailThreadID.map { UInt64(bitPattern: $0) },
            labels: record.labels
        )
    }
}

private extension Collection {
    /// `size` 個ずつに分ける。
    func chunked(_ size: Int) -> [[Element]] {
        var result: [[Element]] = []
        var index = startIndex
        while index != endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index ..< end]))
            index = end
        }
        return result
    }
}
#endif
