import Foundation

/// Mac の中に保存する保存先 (T10)。アプリを終了しても残るので、次に起動したとき
/// すぐに前回の一覧が出て、受信は新しいメールの分だけで済む。一度開いたメールはオフラインでも読める。
///
/// 置き場所 (`directory` の中):
/// ```
/// accounts/<アカウントごとのフォルダ>/index.json   一覧の情報・同期の進み具合・未読数・フォルダ名
/// accounts/<アカウントごとのフォルダ>/raw/<UUID>.eml 開いたメールの生データ (本文と添付)
/// ```
/// - ここにあるのはサーバーのメールの写しだけ。パスワードは置かない (キーチェーンだけ)。
/// - フォルダは本人だけが読める (0700)。
/// - 壊れたファイルや、形式の違うファイルは捨てる。サーバーから取り直せばよいので、起動できなくなることはない。
public actor FileMessageStore: MessageStore {
    /// ファイルの形式。読み方が変わったら上げる (古いファイルは捨てて、取り直す)。
    static let formatVersion = 1

    /// 1 アカウント分のファイルの中身。
    private struct AccountFile: Codable {
        var version: Int
        var account: AccountID
        /// フォルダ名 → 同期の進み具合
        var states: [String: MailboxSyncState] = [:]
        var messages: [StoredMessage] = []
        var inboxUnread: Int?
        /// 役割 (`MailboxRole` の rawValue) → サーバー上のフォルダ名
        var mailboxNames: [String: String] = [:]
        /// メールの ID → 生データのファイル名 (`raw/` の中)
        var rawFiles: [String: String] = [:]
    }

    /// メモリ上の 1 アカウント分。
    private struct AccountData {
        var states: [String: MailboxSyncState] = [:]
        var messages: [MessageID: StoredMessage] = [:]
        var inboxUnread: Int?
        var mailboxNames: [MailboxRole: String] = [:]
        var rawFiles: [MessageID: String] = [:]
    }

    private let root: URL
    private var data: [AccountID: AccountData] = [:]
    /// メールの ID → どのアカウントのものか
    private var owners: [MessageID: AccountID] = [:]

    /// `directory` がなければ作る。前に保存した分を読み込む。
    public init(directory: URL) throws {
        root = directory
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 前からあるフォルダでも、本人だけが読めるようにする
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let accounts = directory.appendingPathComponent("accounts", isDirectory: true)
        try fileManager.createDirectory(at: accounts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var loaded: [AccountID: AccountData] = [:]
        var owners: [MessageID: AccountID] = [:]
        let folders = (try? fileManager.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let (id, account) = Self.load(folder) else {
                // 読めない: 写しなので捨てて、次の同期で取り直す
                try? fileManager.removeItem(at: folder)
                continue
            }
            loaded[id] = account
            for messageID in account.messages.keys { owners[messageID] = id }
        }
        data = loaded
        self.owners = owners
    }

    /// アプリの保存場所 (Application Support の中)。
    public static func defaultDirectory(appFolder: String = "CozyMail") throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)
    }

    // MARK: - MessageStore

    public func syncState(account: AccountID, mailbox: String) -> MailboxSyncState? {
        data[account]?.states[mailbox]
    }

    public func setSyncState(_ state: MailboxSyncState, account: AccountID, mailbox: String) throws {
        try change(account) { $0.states[mailbox] = state }
    }

    public func messages(account: AccountID, mailbox: String) -> [StoredMessage] {
        data[account]?.messages.values.filter { $0.mailbox == mailbox } ?? []
    }

    public func upsert(_ messages: [StoredMessage]) throws {
        let byAccount = Dictionary(grouping: messages, by: \.summary.accountID)
        for (account, messages) in byAccount {
            try change(account) { data in
                for message in messages { data.messages[message.summary.id] = message }
            }
            for message in messages { owners[message.summary.id] = account }
        }
    }

    public func delete(account: AccountID, mailbox: String, uids: Set<UInt32>) throws {
        try removeMessages(account: account) { $0.mailbox == mailbox && uids.contains($0.uid) }
    }

    public func deleteAll(account: AccountID, mailbox: String) throws {
        try removeMessages(account: account, alsoChanging: { $0.states[mailbox] = nil }) { $0.mailbox == mailbox }
    }

    public func deleteAccount(_ account: AccountID) throws {
        if let removed = data.removeValue(forKey: account) {
            for id in removed.messages.keys { owners[id] = nil }
        }
        let folder = folder(for: account)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func inboxUnreadCount(account: AccountID) -> Int? {
        data[account]?.inboxUnread
    }

    public func setInboxUnreadCount(_ count: Int, account: AccountID) throws {
        guard data[account]?.inboxUnread != count else { return }
        try change(account) { $0.inboxUnread = count }
    }

    public func allSummaries() -> [MessageSummary] {
        data.values.flatMap { $0.messages.values.map(\.summary) }
    }

    public func message(id: MessageID) -> StoredMessage? {
        guard let account = owners[id] else { return nil }
        return data[account]?.messages[id]
    }

    public func rawMessage(for id: MessageID) -> Data? {
        guard let account = owners[id], let name = data[account]?.rawFiles[id] else { return nil }
        return try? Data(contentsOf: rawFolder(for: account).appendingPathComponent(name))
    }

    public func setRawMessage(_ raw: Data, for id: MessageID) throws {
        // 一覧にないメールの生データは持たない (消すときに一緒に消せるように)
        guard let account = owners[id] else { return }
        let folder = rawFolder(for: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "\(UUID().uuidString).eml"
        let file = folder.appendingPathComponent(name)
        try raw.write(to: file, options: .atomic)
        let previous = data[account]?.rawFiles[id]
        do {
            try change(account) { $0.rawFiles[id] = name }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        if let previous { try? FileManager.default.removeItem(at: folder.appendingPathComponent(previous)) }
    }

    public func mailboxName(for role: MailboxRole, account: AccountID) -> String? {
        data[account]?.mailboxNames[role]
    }

    public func setMailboxNames(_ names: [MailboxRole: String], account: AccountID) throws {
        guard data[account]?.mailboxNames != names else { return }
        try change(account) { $0.mailboxNames = names }
    }

    // MARK: - 書き込み

    /// メモリ上を変えてから、そのアカウントのファイルに書く。書けなければ元に戻す。
    private func change(_ account: AccountID, _ update: (inout AccountData) -> Void) throws {
        let before = data[account]
        var updated = before ?? AccountData()
        update(&updated)
        data[account] = updated
        do {
            try save(account, updated)
        } catch {
            data[account] = before
            throw error
        }
    }

    private func removeMessages(
        account: AccountID,
        alsoChanging extra: (inout AccountData) -> Void = { _ in },
        where shouldRemove: (StoredMessage) -> Bool
    ) throws {
        guard let current = data[account] else { return }
        let removed = current.messages.values.filter(shouldRemove).map(\.summary.id)
        let removedFiles = removed.compactMap { current.rawFiles[$0] }
        try change(account) { data in
            for id in removed {
                data.messages[id] = nil
                data.rawFiles[id] = nil
            }
            extra(&data)
        }
        for id in removed { owners[id] = nil }
        // ファイルの一覧から外したあとで消す (途中で失敗しても、一覧が消えたファイルを指さない)
        let folder = rawFolder(for: account)
        for name in removedFiles { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    private func save(_ account: AccountID, _ data: AccountData) throws {
        let file = AccountFile(
            version: Self.formatVersion,
            account: account,
            states: data.states,
            messages: data.messages.values.sorted { $0.summary.id.rawValue < $1.summary.id.rawValue },
            inboxUnread: data.inboxUnread,
            mailboxNames: Dictionary(uniqueKeysWithValues: data.mailboxNames.map { ($0.key.rawValue, $0.value) }),
            rawFiles: Dictionary(uniqueKeysWithValues: data.rawFiles.map { ($0.key.rawValue, $0.value) })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(file)
        let folder = folder(for: account)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoded.write(to: folder.appendingPathComponent("index.json"), options: .atomic)
    }

    // MARK: - 読み込み

    /// 1 アカウント分を読む。読めなければ nil (呼び出し側でフォルダごと捨てる)。
    private static func load(_ folder: URL) -> (AccountID, AccountData)? {
        let index = folder.appendingPathComponent("index.json")
        guard
            let raw = try? Data(contentsOf: index),
            let file = try? JSONDecoder().decode(AccountFile.self, from: raw),
            file.version == formatVersion,
            folder.lastPathComponent == folderName(for: file.account)
        else { return nil }

        var account = AccountData()
        account.states = file.states
        for message in file.messages where message.summary.accountID == file.account {
            account.messages[message.summary.id] = message
        }
        account.inboxUnread = file.inboxUnread
        for (role, name) in file.mailboxNames {
            if let role = MailboxRole(rawValue: role) { account.mailboxNames[role] = name }
        }
        // 自分で付けた名前 (`<UUID>.eml`) だけを信じる。フォルダの外を指す名前は使わない。
        let rawFolder = folder.appendingPathComponent("raw", isDirectory: true)
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: rawFolder.path)) ?? [])
        for (id, name) in file.rawFiles where isRawFileName(name) && existing.contains(name) {
            let id = MessageID(id)
            if account.messages[id] != nil { account.rawFiles[id] = name }
        }
        // どのメールにも使われていない生データ (書いている途中で終了したなど) は消す
        let used = Set(account.rawFiles.values)
        for name in existing where !used.contains(name) {
            try? FileManager.default.removeItem(at: rawFolder.appendingPathComponent(name))
        }
        return (file.account, account)
    }

    private static func isRawFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".eml") else { return false }
        return UUID(uuidString: String(name.dropLast(4))) != nil
    }

    // MARK: - 場所

    /// アカウントの ID をそのままファイル名にしない (「/」や「..」があっても、フォルダの外に出ないように)。
    private static func folderName(for account: AccountID) -> String {
        "a-" + account.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func folder(for account: AccountID) -> URL {
        root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(Self.folderName(for: account), isDirectory: true)
    }

    private func rawFolder(for account: AccountID) -> URL {
        folder(for: account).appendingPathComponent("raw", isDirectory: true)
    }
}
