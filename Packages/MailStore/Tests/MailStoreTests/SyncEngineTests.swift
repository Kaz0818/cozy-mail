import Foundation
import MailCore
import Testing
@testable import MailStore

@Suite struct SyncEngineTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-12 頃
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    private func engine(_ store: InMemoryMessageStore) -> SyncEngine {
        let now = now
        return SyncEngine(store: store, calendar: calendar, now: { now })
    }

    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")

    /// Yahoo! のような、SPECIAL-USE のある一般的なサーバー。
    private func yahooServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Sent", specialUse: .sent)
        await server.add(.init(uid: 10, date: daysAgo(40), subject: "old", from: "Old <old@example.com>"), to: "INBOX")
        await server.add(.init(uid: 11, date: daysAgo(3), subject: "=?UTF-8?B?5LyB55S7?=", from: "山田 <y@example.com>",
                               flags: ["\\Seen"]), to: "INBOX")
        await server.add(.init(uid: 12, date: daysAgo(1), subject: "two", from: "b@example.com",
                               contentType: "multipart/mixed; boundary=x"), to: "INBOX")
        await server.add(.init(uid: 5, date: daysAgo(2), subject: "sent one", from: "me@yahoo.example",
                               flags: ["\\Seen"]), to: "Sent")
        return server
    }

    // MARK: - 初回

    @Test func initialSyncFetchesOnlyTheLast30Days() async throws {
        let store = InMemoryMessageStore()
        let server = await yahooServer()
        let report = try await engine(store).sync(account: yahoo, session: server)

        let inbox = try await store.messages(account: yahoo.id, mailbox: "INBOX")
        #expect(inbox.map(\.uid).sorted() == [11, 12])
        #expect(report.added == 3)
        #expect(try await store.syncState(account: yahoo.id, mailbox: "INBOX") == MailboxSyncState(uidValidity: 1, highestUID: 12))
        #expect(try await store.messages(account: yahoo.id, mailbox: "Sent").map(\.summary.mailbox) == [.sent])
    }

    @Test func summaryIsBuiltFromTheHeaders() async throws {
        let store = InMemoryMessageStore()
        _ = try await engine(store).sync(account: yahoo, session: await yahooServer())

        let inbox = try await store.messages(account: yahoo.id, mailbox: "INBOX").sorted { $0.uid < $1.uid }
        let first = try #require(inbox.first).summary
        #expect(first.subject == "企画")
        #expect(first.sender == Contact(name: "山田", address: "y@example.com"))
        #expect(first.isRead)
        #expect(first.mailbox == .inbox)
        #expect(first.accountID == yahoo.id)
        #expect(abs(first.date.timeIntervalSince(daysAgo(3))) < 1)
        #expect(!first.hasAttachments)
        #expect(inbox[1].summary.hasAttachments)
        #expect(inbox[1].summary.sender == Contact(name: "", address: "b@example.com"))
        #expect(!inbox[1].summary.isRead)
    }

    // MARK: - 2 回目以降

    @Test func incrementalSyncAddsNewUpdatesFlagsAndRemovesDeleted() async throws {
        let store = InMemoryMessageStore()
        let server = await yahooServer()
        let engine = engine(store)
        _ = try await engine.sync(account: yahoo, session: server)

        await server.add(.init(uid: 13, date: daysAgo(0), subject: "new", from: "c@example.com"), to: "INBOX")
        await server.setFlags(["\\Seen", "\\Flagged"], uid: 12, in: "INBOX")
        await server.remove(uid: 11, from: "INBOX")
        await server.clearCalls()

        let report = try await engine.sync(account: yahoo, session: server)

        let inbox = try await store.messages(account: yahoo.id, mailbox: "INBOX").sorted { $0.uid < $1.uid }
        #expect(inbox.map(\.uid) == [12, 13])
        #expect(inbox[0].summary.isRead && inbox[0].summary.isStarred)
        #expect(report.added == 1)
        #expect(report.removed == 1)
        #expect(report.updated == 1)
        let calls = await server.calls
        #expect(calls.contains("FETCH INBOX 13:*"))
        #expect(calls.contains("FLAGS INBOX 11:12"))
        #expect(!calls.contains("SEARCH INBOX"))
        #expect(try await store.syncState(account: yahoo.id, mailbox: "INBOX")?.highestUID == 13)
    }

    @Test func noNewMailDoesNotDuplicateTheLastMessage() async throws {
        let store = InMemoryMessageStore()
        let server = await yahooServer()
        let engine = engine(store)
        _ = try await engine.sync(account: yahoo, session: server)

        let report = try await engine.sync(account: yahoo, session: server)

        #expect(report.added == 0)
        #expect(try await store.messages(account: yahoo.id, mailbox: "INBOX").count == 2)
    }

    @Test func uidValidityChangeRefetchesTheMailbox() async throws {
        let store = InMemoryMessageStore()
        let server = await yahooServer()
        let engine = engine(store)
        _ = try await engine.sync(account: yahoo, session: server)
        let before = try await store.messages(account: yahoo.id, mailbox: "INBOX").map(\.summary.id)

        await server.resetUIDValidity("INBOX", to: 99)
        await server.clearCalls()
        _ = try await engine.sync(account: yahoo, session: server)

        let after = try await store.messages(account: yahoo.id, mailbox: "INBOX")
        #expect(after.count == 2)
        #expect(Set(after.map(\.summary.id)).isDisjoint(with: before))
        #expect(await server.calls.contains("SEARCH INBOX"))
        #expect(try await store.syncState(account: yahoo.id, mailbox: "INBOX")?.uidValidity == 99)
    }

    @Test func emptyMailboxRemembersUIDNextSoTheNextSyncDoesNotFetchEverything() async throws {
        let store = InMemoryMessageStore()
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.add(.init(uid: 50, date: daysAgo(90), subject: "ancient", from: "a@example.com"), to: "INBOX")
        let engine = engine(store)
        _ = try await engine.sync(account: yahoo, session: server)
        #expect(try await store.syncState(account: yahoo.id, mailbox: "INBOX")?.highestUID == 50)

        await server.add(.init(uid: 51, date: daysAgo(0), subject: "fresh", from: "a@example.com"), to: "INBOX")
        await server.clearCalls()
        _ = try await engine.sync(account: yahoo, session: server)

        #expect(await server.calls.contains("FETCH INBOX 51:*"))
        #expect(try await store.messages(account: yahoo.id, mailbox: "INBOX").map(\.uid) == [51])
    }

    // MARK: - フォルダの選び方

    @Test func foldersWithoutSpecialUseAreRecognisedByName() async throws {
        let server = FakeMailServer()
        await server.addFolder("Inbox")
        await server.addFolder("Draft")
        await server.addFolder("Bulk Mail")
        await server.addFolder("Trash")
        await server.addFolder("Sent")
        await server.addFolder("Receipts")
        let targets = SyncEngine.targets(for: .yahoo, mailboxes: try await server.listMailboxes())
        let roles = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0.role) })
        #expect(roles == ["Inbox": .inbox, "Draft": .drafts, "Bulk Mail": .junk, "Trash": .trash, "Sent": .sent])
    }

    @Test func specialUseWinsOverNames() async throws {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Sent")
        await server.addFolder("送信済み", specialUse: .sent)
        let targets = SyncEngine.targets(for: .other, mailboxes: try await server.listMailboxes())
        #expect(targets.first { $0.role == .sent }?.name == "送信済み")
        #expect(targets.filter { $0.role == .sent }.count == 1)
    }

    // MARK: - Gmail

    private func gmailServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]", selectable: false)
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Sent Mail", specialUse: .sent)
        await server.addFolder("[Gmail]/Drafts", specialUse: .drafts)
        await server.addFolder("[Gmail]/Spam", specialUse: .junk)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.addFolder("[Gmail]/Starred", specialUse: .flagged)
        let all = "[Gmail]/All Mail"
        await server.add(.init(uid: 1, date: daysAgo(1), subject: "in inbox", from: "a@example.com",
                               gmailMessageID: 101, labels: ["\\Inbox", "\\Important"]), to: all)
        await server.add(.init(uid: 2, date: daysAgo(1), subject: "starred inbox", from: "a@example.com",
                               flags: ["\\Flagged"], gmailMessageID: 102, labels: ["\\Inbox", "\\Starred"]), to: all)
        await server.add(.init(uid: 3, date: daysAgo(1), subject: "i sent", from: "me@gmail.com",
                               flags: ["\\Seen"], gmailMessageID: 103, labels: ["\\Sent"]), to: all)
        await server.add(.init(uid: 4, date: daysAgo(1), subject: "draft", from: "me@gmail.com",
                               gmailMessageID: 104, labels: ["\\Draft"]), to: all)
        await server.add(.init(uid: 5, date: daysAgo(1), subject: "archived", from: "a@example.com",
                               flags: ["\\Seen"], gmailMessageID: 105, labels: ["Work"]), to: all)
        await server.add(.init(uid: 1, date: daysAgo(1), subject: "spam", from: "x@spam.example",
                               gmailMessageID: 201), to: "[Gmail]/Spam")
        return server
    }

    @Test func gmailSyncsAllMailSpamAndTrashOnly() async throws {
        let server = await gmailServer()
        let targets = SyncEngine.targets(for: .gmail, mailboxes: try await server.listMailboxes())
        #expect(targets.map(\.name) == ["[Gmail]/All Mail", "[Gmail]/Spam", "[Gmail]/Trash"])
        #expect(targets.map(\.role) == [nil, .junk, .trash])
    }

    @Test func gmailRolesComeFromLabelsSoNothingIsDuplicated() async throws {
        let store = InMemoryMessageStore()
        _ = try await engine(store).sync(account: gmail, session: await gmailServer())

        let all = try await store.messages(account: gmail.id, mailbox: "[Gmail]/All Mail").sorted { $0.uid < $1.uid }
        #expect(all.map(\.summary.mailbox) == [.inbox, .inbox, .sent, .drafts, .archive])
        #expect(all.map(\.summary.isStarred) == [false, true, false, false, false])
        #expect(all.map(\.gmailMessageID) == [101, 102, 103, 104, 105])
        #expect(try await store.messages(account: gmail.id, mailbox: "[Gmail]/Spam").map(\.summary.mailbox) == [.junk])

        let summaries = try await store.allSummaries()
        #expect(summaries.filter { $0.mailbox == .inbox }.count == 2)
        #expect(Set(summaries.map(\.id)).count == summaries.count)
    }

    @Test func gmailLabelChangesMoveMessagesBetweenFolders() async throws {
        let store = InMemoryMessageStore()
        let server = await gmailServer()
        let engine = engine(store)
        _ = try await engine.sync(account: gmail, session: server)

        // Web 版で「アーカイブ」した = 受信トレイのラベルが外れた
        await server.setLabels(["\\Important"], uid: 1, in: "[Gmail]/All Mail")
        _ = try await engine.sync(account: gmail, session: server)

        let message = try await store.messages(account: gmail.id, mailbox: "[Gmail]/All Mail").first { $0.uid == 1 }
        #expect(message?.summary.mailbox == .archive)
        #expect(message?.labels == ["\\Important"])
    }

    // MARK: - 複数アカウント

    @Test func accountsDoNotOverwriteEachOther() async throws {
        let store = InMemoryMessageStore()
        let engine = engine(store)
        _ = try await engine.sync(account: yahoo, session: await yahooServer())
        let other = Account(id: AccountID("yahoo2"), provider: .yahoo, emailAddress: "two@yahoo.example", displayName: "2")
        _ = try await engine.sync(account: other, session: await yahooServer())

        #expect(try await store.messages(account: yahoo.id, mailbox: "INBOX").count == 2)
        #expect(try await store.messages(account: other.id, mailbox: "INBOX").count == 2)
        #expect(try await store.allSummaries().count == 6)
    }
}
