import Foundation
import MailCore
@testable import MailStore

/// テスト用の偽のメールサーバー。フォルダとメールをメモリ上に持ち、呼ばれた命令を記録する。
/// 本物の IMAP と同じく、`fromUID` 以降を求められて該当がなければ、最後の 1 通を返す。
actor FakeMailServer: MailServerSession {
    struct Message {
        var uid: UInt32
        var date: Date
        var subject: String
        var from: String
        var flags: [String] = []
        var gmailMessageID: UInt64?
        var labels: [String] = []
        var contentType = "text/plain; charset=utf-8"
        /// 宛先 (To)。空なら書かない。
        var to = ""
        /// Message-ID (`<>` なし)。nil なら `<UID@example.com>`。
        var messageID: String?
        /// 本文。nil なら `body <UID>`。
        var body: String?
    }

    struct Folder {
        var info: IMAPMailbox
        var uidValidity: UInt32
        var uidNext: UInt32
        var messages: [Message] = []
    }

    private(set) var folders: [String: Folder] = [:]
    private var order: [String] = []
    private(set) var calls: [String] = []

    func addFolder(_ name: String, specialUse: IMAPSpecialUse? = nil, uidValidity: UInt32 = 1, selectable: Bool = true) {
        folders[name] = Folder(
            info: IMAPMailbox(name: name, rawName: name, separator: "/", specialUse: specialUse, isSelectable: selectable),
            uidValidity: uidValidity,
            uidNext: 1
        )
        order.append(name)
    }

    func add(_ message: Message, to folder: String) {
        guard var entry = folders[folder] else { return }
        entry.messages.append(message)
        entry.uidNext = max(entry.uidNext, message.uid + 1)
        folders[folder] = entry
    }

    func remove(uid: UInt32, from folder: String) {
        folders[folder]?.messages.removeAll { $0.uid == uid }
    }

    func setFlags(_ flags: [String], uid: UInt32, in folder: String) {
        guard let index = folders[folder]?.messages.firstIndex(where: { $0.uid == uid }) else { return }
        folders[folder]?.messages[index].flags = flags
    }

    func setLabels(_ labels: [String], uid: UInt32, in folder: String) {
        guard let index = folders[folder]?.messages.firstIndex(where: { $0.uid == uid }) else { return }
        folders[folder]?.messages[index].labels = labels
    }

    func resetUIDValidity(_ folder: String, to value: UInt32) {
        folders[folder]?.uidValidity = value
    }

    func clearCalls() {
        calls = []
    }

    // MARK: - MailServerSession

    func listMailboxes() async throws -> [IMAPMailbox] {
        calls.append("LIST")
        return order.compactMap { folders[$0]?.info }
    }

    func examine(_ mailbox: String) async throws -> IMAPMailboxStatus {
        calls.append("EXAMINE \(mailbox)")
        let folder = try folder(mailbox)
        return IMAPMailboxStatus(messageCount: folder.messages.count, uidValidity: folder.uidValidity, uidNext: folder.uidNext)
    }

    func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] {
        calls.append("SEARCH \(mailbox)")
        let start = calendar.startOfDay(for: date)
        return try folder(mailbox).messages.filter { $0.date >= start }.map(\.uid).sorted()
    }

    func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        calls.append("FETCH \(mailbox) \(uids.sorted())")
        let wanted = Set(uids)
        return try folder(mailbox).messages.filter { wanted.contains($0.uid) }.map { header($0, gmail: includeGmailAttributes) }
    }

    func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        calls.append("FETCH \(mailbox) \(uid):*")
        let messages = try folder(mailbox).messages.sorted { $0.uid < $1.uid }
        let newer = messages.filter { $0.uid >= uid }
        // IMAP の決まり: n:* で該当がなくても、最後の 1 通が返る
        let result = newer.isEmpty ? Array(messages.suffix(1)) : newer
        return result.map { header($0, gmail: includeGmailAttributes) }
    }

    func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data {
        calls.append("BODY \(mailbox) \(uid)")
        guard let message = try folder(mailbox).messages.first(where: { $0.uid == uid }) else {
            throw FakeServerError.noSuchMailbox("\(mailbox) uid \(uid)")
        }
        let text = message.body ?? "body \(uid)"
        return Data("Subject: \(message.subject)\r\nFrom: \(message.from)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(text)\r\n".utf8)
    }

    /// サーバー側の検索 (T27): 件名・差出人・本文のどこかに、言葉を全部含むメール (大文字・小文字は区別しない)。
    func searchUIDs(in mailbox: String, text: String) async throws -> [UInt32] {
        calls.append("SEARCH TEXT \(mailbox) \(text)")
        let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty else { return [] }
        return try folder(mailbox).messages.filter { message in
            let haystack = "\(message.subject) \(message.from) \(message.body ?? "body \(message.uid)")".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.map(\.uid).sorted()
    }

    /// true にすると、次の書き込み (フラグ・ラベル・移動) が失敗する。
    private(set) var failNextWrite = false

    func setFailNextWrite(_ value: Bool) {
        failNextWrite = value
    }

    private func checkWrite() throws {
        if failNextWrite {
            failNextWrite = false
            throw FakeServerError.writeRejected
        }
    }

    func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {
        calls.append("STORE \(mailbox) \(add ? "+" : "-")\(flags.joined(separator: " ")) \(uids.sorted())")
        try checkWrite()
        guard var entry = folders[mailbox] else { throw FakeServerError.noSuchMailbox(mailbox) }
        for index in entry.messages.indices where uids.contains(entry.messages[index].uid) {
            var current = entry.messages[index].flags.filter { !flags.contains($0) }
            if add { current += flags }
            entry.messages[index].flags = current
        }
        folders[mailbox] = entry
    }

    func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {
        calls.append("LABELS \(mailbox) \(add ? "+" : "-")\(labels.joined(separator: " ")) \(uids.sorted())")
        try checkWrite()
        guard var entry = folders[mailbox] else { throw FakeServerError.noSuchMailbox(mailbox) }
        for index in entry.messages.indices where uids.contains(entry.messages[index].uid) {
            var current = entry.messages[index].labels.filter { !labels.contains($0) }
            if add { current += labels }
            entry.messages[index].labels = current
        }
        folders[mailbox] = entry
    }

    /// 本物と同じく、移した先では新しい UID になる。
    func move(uids: [UInt32], from mailbox: String, to target: String) async throws {
        calls.append("MOVE \(mailbox) -> \(target) \(uids.sorted())")
        try checkWrite()
        guard var source = folders[mailbox], var destination = folders[target] else {
            throw FakeServerError.noSuchMailbox("\(mailbox) or \(target)")
        }
        let moving = source.messages.filter { uids.contains($0.uid) }
        source.messages.removeAll { uids.contains($0.uid) }
        for var message in moving {
            message.uid = destination.uidNext
            destination.uidNext += 1
            destination.messages.append(message)
        }
        folders[mailbox] = source
        folders[target] = destination
    }

    /// `APPEND` で入れたメール (フォルダ名、中身)。
    private(set) var appended: [(folder: String, data: Data)] = []

    func append(_ message: Data, to mailbox: String, flags: [String]) async throws {
        calls.append("APPEND \(mailbox) \(flags)")
        try checkWrite()
        guard var folder = folders[mailbox] else { throw FakeServerError.noSuchMailbox(mailbox) }
        appended.append((mailbox, message))
        // 本物と同じく、入れたメールをフォルダに置く (置くのは `keepsAppendedMessages` のときだけ。前からのテストを変えないため)
        guard keepsAppendedMessages else { return }
        let parsed = try? MIMEParser.parse(message)
        folder.messages.append(Message(
            uid: folder.uidNext, date: parsed?.date ?? Date(timeIntervalSince1970: 0), subject: parsed?.subject ?? "",
            from: parsed?.from.first?.address ?? "", flags: flags, messageID: parsed?.messageID
        ))
        folder.uidNext += 1
        folders[mailbox] = folder
    }

    /// true なら、`APPEND` したメールをフォルダに置く。
    private(set) var keepsAppendedMessages = false

    func setKeepsAppendedMessages(_ value: Bool) {
        keepsAppendedMessages = value
    }

    // MARK: - サーバーの下書き (T23b)

    /// false なら、UIDPLUS のないサーバーのふり (消す命令は断る)。
    private(set) var hasUIDPlus = true

    func setHasUIDPlus(_ value: Bool) {
        hasUIDPlus = value
    }

    func supportsUIDPlus() async throws -> Bool {
        hasUIDPlus
    }

    /// 本物の `SEARCH HEADER` と同じく、見出しに言葉を「含む」メールを返す (ちょうど同じでなくても当たる)。
    /// ここでは Message-ID だけを見る。
    func searchUIDs(in mailbox: String, header field: String, containing value: String) async throws -> [UInt32] {
        calls.append("SEARCH \(mailbox) \(field) \(value)")
        guard field.caseInsensitiveCompare("Message-ID") == .orderedSame else { return [] }
        return try folder(mailbox).messages.filter { message in
            (message.messageID ?? "\(message.uid)@example.com").contains(value)
        }.map(\.uid).sorted()
    }

    func deleteMessages(uids: [UInt32], in mailbox: String) async throws {
        guard !uids.isEmpty else { return }
        calls.append("DELETE \(mailbox) \(uids.sorted())")
        guard hasUIDPlus else { throw IMAPError.unsupported("UIDPLUS") }
        try checkWrite()
        guard var folder = folders[mailbox] else { throw FakeServerError.noSuchMailbox(mailbox) }
        folder.messages.removeAll { uids.contains($0.uid) }
        folders[mailbox] = folder
    }

    /// フォルダにあるメールの Message-ID (確かめる用)。
    func messageIDs(in mailbox: String) -> [String] {
        (folders[mailbox]?.messages ?? []).map { $0.messageID ?? "\($0.uid)@example.com" }
    }

    func close() async {
        calls.append("CLOSE")
    }

    /// 本物の STATUS と同じく、期間に関係なくフォルダ全体の未読を数える。
    func unreadCount(of mailbox: String) async throws -> Int {
        calls.append("STATUS \(mailbox)")
        return try folder(mailbox).messages.filter { !$0.flags.contains("\\Seen") }.count
    }

    func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
        calls.append("FLAGS \(mailbox) \(uids.lowerBound):\(uids.upperBound)")
        return try folder(mailbox).messages.filter { uids.contains($0.uid) }.map {
            IMAPFetchedHeader(
                uid: $0.uid,
                flags: $0.flags,
                gmailMessageID: includeGmailAttributes ? $0.gmailMessageID : nil,
                gmailLabels: includeGmailAttributes ? $0.labels : []
            )
        }
    }

    // MARK: - 部品

    private func folder(_ name: String) throws -> Folder {
        guard let folder = folders[name] else { throw FakeServerError.noSuchMailbox(name) }
        return folder
    }

    private func header(_ message: Message, gmail: Bool) -> IMAPFetchedHeader {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let raw = "From: \(message.from)\r\n" + (message.to.isEmpty ? "" : "To: \(message.to)\r\n")
            + "Subject: \(message.subject)\r\nDate: \(formatter.string(from: message.date))\r\n"
            + "Message-ID: <\(message.messageID ?? "\(message.uid)@example.com")>\r\nContent-Type: \(message.contentType)\r\n\r\n"
        return IMAPFetchedHeader(
            uid: message.uid,
            flags: message.flags,
            size: 1000,
            headerData: Data(raw.utf8),
            gmailMessageID: gmail ? message.gmailMessageID : nil,
            gmailThreadID: nil,
            gmailLabels: gmail ? message.labels : []
        )
    }
}

enum FakeServerError: Error, Equatable {
    case noSuchMailbox(String)
    case writeRejected
}
