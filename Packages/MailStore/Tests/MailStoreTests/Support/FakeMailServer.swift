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
        return Data("Subject: \(message.subject)\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nbody \(uid)\r\n".utf8)
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
        let raw = "From: \(message.from)\r\nSubject: \(message.subject)\r\nDate: \(formatter.string(from: message.date))\r\n"
            + "Message-ID: <\(message.uid)@example.com>\r\nContent-Type: \(message.contentType)\r\n\r\n"
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

enum FakeServerError: Error {
    case noSuchMailbox(String)
}
