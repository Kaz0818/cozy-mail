import Foundation
import MailCore
import Testing
@testable import MailStore

/// 同期で「新しく受信トレイに来た未読メール」を知らせる (T20b の通知のもと)。
@Suite struct NewInboxMailTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")

    private func engine(_ store: InMemoryMessageStore) -> SyncEngine {
        let now = now
        return SyncEngine(store: store, now: { now })
    }

    private func yahooServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Junk", specialUse: .junk)
        await server.add(.init(uid: 1, date: now.addingTimeInterval(-3600), subject: "前からある", from: "a@example.com"), to: "INBOX")
        return server
    }

    /// 初めての同期 (たまっていた分) は「新着」にしない。
    @Test func theFirstSyncReportsNothingNew() async throws {
        let store = InMemoryMessageStore()
        let report = try await engine(store).sync(account: yahoo, session: await yahooServer())
        #expect(report.added == 1)
        #expect(report.newInboxMessages.isEmpty)
    }

    @Test func aNewUnreadInboxMessageIsReported() async throws {
        let store = InMemoryMessageStore()
        let server = await yahooServer()
        _ = try await engine(store).sync(account: yahoo, session: server)
        await server.add(.init(uid: 2, date: now, subject: "新しいメール", from: "田中 <t@example.com>"), to: "INBOX")
        await server.add(.init(uid: 3, date: now, subject: "読んだもの", from: "b@example.com", flags: ["\\Seen"]), to: "INBOX")
        await server.add(.init(uid: 1, date: now, subject: "迷惑", from: "x@spam.example"), to: "Junk")

        let report = try await engine(store).sync(account: yahoo, session: server)
        #expect(report.newInboxMessages.map(\.subject) == ["新しいメール"])
        #expect(report.newInboxMessages.first?.sender == Contact(name: "田中", address: "t@example.com"))
    }

    @Test func gmailReportsOnlyMailWithTheInboxLabel() async throws {
        let store = InMemoryMessageStore()
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        let all = "[Gmail]/All Mail"
        await server.add(.init(uid: 1, date: now, subject: "前から", from: "a@example.com", gmailMessageID: 1, labels: ["\\Inbox"]), to: all)
        _ = try await engine(store).sync(account: gmail, session: server)
        await server.add(.init(uid: 2, date: now, subject: "受信トレイ", from: "a@example.com", gmailMessageID: 2, labels: ["\\Inbox"]), to: all)
        await server.add(.init(uid: 3, date: now, subject: "自分が送った", from: "me@gmail.com",
                               flags: ["\\Seen"], gmailMessageID: 3, labels: ["\\Sent"]), to: all)
        await server.add(.init(uid: 4, date: now, subject: "フィルタでアーカイブ", from: "a@example.com", gmailMessageID: 4, labels: ["Work"]), to: all)

        let report = try await engine(store).sync(account: gmail, session: server)
        #expect(report.newInboxMessages.map(\.subject) == ["受信トレイ"])
    }
}
