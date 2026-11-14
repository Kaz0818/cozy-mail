import AccountKit
import Foundation
import MailCore
import MailStore
import Testing
@testable import CozyMail

/// 新着の通知 (T20b)。本物のサーバーにも、Mac の通知センターにも触れない。
@MainActor @Suite struct MailServiceNotificationTests {
    /// 受信トレイだけを持つ偽のサーバー。
    actor InboxSession: MailServerSession {
        struct Mail { var uid: UInt32; var subject: String; var from: String; var seen = false }
        private var mails: [Mail]

        init(_ mails: [Mail]) { self.mails = mails }

        func deliver(_ mail: Mail) { mails.append(mail) }

        private func header(_ mail: Mail) -> IMAPFetchedHeader {
            let raw = "From: \(mail.from)\r\nSubject: \(mail.subject)\r\nDate: Fri, 13 Nov 2026 10:00:00 +0900\r\n\r\n"
            return IMAPFetchedHeader(uid: mail.uid, flags: mail.seen ? ["\\Seen"] : [], size: 100, headerData: Data(raw.utf8))
        }

        func listMailboxes() async throws -> [IMAPMailbox] {
            [IMAPMailbox(name: "INBOX", rawName: "INBOX", separator: "/", specialUse: .inbox, isSelectable: true)]
        }
        func examine(_ mailbox: String) async throws -> IMAPMailboxStatus {
            IMAPMailboxStatus(messageCount: mails.count, uidValidity: 1, uidNext: (mails.map(\.uid).max() ?? 0) + 1)
        }
        func searchUIDs(in mailbox: String, since date: Date, calendar: Calendar) async throws -> [UInt32] { mails.map(\.uid) }
        func fetchHeaders(in mailbox: String, uids: [UInt32], includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
            mails.filter { uids.contains($0.uid) }.map(header)
        }
        func fetchHeaders(in mailbox: String, fromUID uid: UInt32, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
            let found = mails.filter { $0.uid >= uid }
            return (found.isEmpty ? Array(mails.suffix(1)) : found).map(header)
        }
        func fetchFlags(in mailbox: String, uids: ClosedRange<UInt32>, includeGmailAttributes: Bool) async throws -> [IMAPFetchedHeader] {
            mails.filter { uids.contains($0.uid) }.map(header)
        }
        func unreadCount(of mailbox: String) async throws -> Int { mails.filter { !$0.seen }.count }
        func fetchMessage(in mailbox: String, uid: UInt32) async throws -> Data { Data() }
        func setFlags(_ flags: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func setGmailLabels(_ labels: [String], add: Bool, in mailbox: String, uids: [UInt32]) async throws {}
        func move(uids: [UInt32], from mailbox: String, to target: String) async throws {}
        func append(_ message: Data, to mailbox: String, flags: [String]) async throws {}
        func close() async {}
    }

    /// 出された通知を貯める。
    final class Posted {
        var alerts: [NewMailAlert] = []
    }

    private struct SavedAccount: Encodable {
        var account: Account
        var imap: ServerSettings
        var smtp: ServerSettings
    }

    private let account = Account(id: AccountID("a"), provider: .yahoo, emailAddress: "a@yahoo.example", displayName: "Yahoo!")

    private func service(_ session: InboxSession, posted: Posted, enabled: Bool = true) throws -> MailService {
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode([SavedAccount(
            account: account,
            imap: ServerSettings(host: "imap.example.com", port: 993),
            smtp: ServerSettings(host: "smtp.example.com", port: 465)
        )]))
        let secrets = InMemorySecretStore()
        try secrets.set(Data("pw".utf8), for: "password.a")
        let directory = AccountDirectory(
            storage: storage, secrets: secrets,
            connector: { _, _ in session },
            senderConnector: { _, _ in throw CancellationError() }
        )
        return MailService(
            directory: directory, store: InMemoryMessageStore(),
            notifications: .init(isEnabled: { enabled }, post: { posted.alerts += $0 })
        )
    }

    /// 起動して最初の同期 (たまっていた分) では通知しない。
    @Test func theFirstSyncAfterLaunchDoesNotNotify() async throws {
        let session = InboxSession([.init(uid: 1, subject: "前から", from: "a@example.com")])
        let posted = Posted()
        let service = try service(session, posted: posted)
        await service.start()
        #expect(posted.alerts.isEmpty)
    }

    @Test func mailThatArrivesLaterIsNotified() async throws {
        let session = InboxSession([.init(uid: 1, subject: "前から", from: "a@example.com")])
        let posted = Posted()
        let service = try service(session, posted: posted)
        await service.start()
        await session.deliver(.init(uid: 2, subject: "新しいメール", from: "田中 <t@example.com>"))
        await service.sync(accountID: account.id)
        #expect(posted.alerts.map(\.subtitle) == ["新しいメール"])
        #expect(posted.alerts.first?.title == "田中")
        #expect(posted.alerts.first?.accountName == "Yahoo!")
        // もう一度同期しても、同じメールで二度は知らせない
        await service.sync(accountID: account.id)
        #expect(posted.alerts.count == 1)
    }

    @Test func turningNotificationsOffStopsThem() async throws {
        let session = InboxSession([.init(uid: 1, subject: "前から", from: "a@example.com")])
        let posted = Posted()
        let service = try service(session, posted: posted, enabled: false)
        await service.start()
        await session.deliver(.init(uid: 2, subject: "新しいメール", from: "t@example.com"))
        await service.sync(accountID: account.id)
        #expect(posted.alerts.isEmpty)
    }

    /// 通知を押すと、そのメールを開くように画面に頼む。
    @Test func openingAnAlertAsksTheWindowToShowTheMessage() throws {
        let service = try service(InboxSession([]), posted: Posted())
        let before = service.openRequest
        service.requestOpen(MessageID("a/2"))
        #expect(service.openRequest.messageID == MessageID("a/2"))
        #expect(service.openRequest != before)
    }
}

/// 通知から開くメール (T20b)。統合受信トレイに切り替えて、そのメールを選ぶ。
@MainActor @Suite struct InboxModelOpenFromNotificationTests {
    @Test func showsTheMessageInTheUnifiedInbox() async throws {
        let model = InboxModel(repository: PreviewMailRepository())
        await model.load()
        let yahoo = try #require(model.accounts.last?.account)
        await model.select(.account(yahoo.id, .sent))
        let target = try #require(try await PreviewMailRepository().messages(in: .unified(.inbox), filter: .all).last)

        await model.show(target.id)

        #expect(model.selection == .unified(.inbox))
        #expect(model.selectedMessageID == target.id)
    }

    @Test func aSummaryAlertJustShowsTheUnifiedInbox() async throws {
        let model = InboxModel(repository: PreviewMailRepository())
        await model.load()
        let yahoo = try #require(model.accounts.last?.account)
        await model.select(.account(yahoo.id, .sent))
        await model.show(nil)
        #expect(model.selection == .unified(.inbox))
    }
}
