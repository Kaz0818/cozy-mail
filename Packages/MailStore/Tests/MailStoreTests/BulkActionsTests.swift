import Foundation
import MailCore
import Testing
@testable import MailStore

/// 複数のメールをまとめて操作する (T26、US-17)。サーバーへは、アカウントとフォルダごとにまとめて 1 回で送る。
@Suite struct BulkActionsTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "Gmail")

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86400)
    }

    private func yahooServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("Trash", specialUse: .trash)
        await server.addFolder("Archive", specialUse: .archive)
        await server.add(.init(uid: 11, date: daysAgo(1), subject: "one", from: "a@example.com"), to: "INBOX")
        await server.add(.init(uid: 12, date: daysAgo(1), subject: "two", from: "b@example.com"), to: "INBOX")
        await server.add(.init(uid: 13, date: daysAgo(1), subject: "three", from: "c@example.com", flags: ["\\Seen"]), to: "INBOX")
        await server.add(.init(uid: 21, date: daysAgo(1), subject: "trashed", from: "d@example.com", flags: ["\\Seen"]), to: "Trash")
        return server
    }

    private func gmailServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.add(.init(uid: 1, date: daysAgo(1), subject: "g1", from: "a@example.com",
                               gmailMessageID: 101, labels: ["\\Inbox"]), to: "[Gmail]/All Mail")
        await server.add(.init(uid: 2, date: daysAgo(1), subject: "g2", from: "b@example.com",
                               gmailMessageID: 102, labels: ["\\Inbox"]), to: "[Gmail]/All Mail")
        return server
    }

    /// 2 つのアカウントを同期した保存先と、それを使うリポジトリ。
    private func setUp(
        _ pairs: [(Account, FakeMailServer)]
    ) async throws -> (LiveMailRepository, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        let now = now
        for (account, server) in pairs {
            _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
            await server.clearCalls()
        }
        let accounts = pairs.map(\.0)
        let servers = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, $0.1) })
        let repository = LiveMailRepository(
            store: store, accounts: { accounts },
            openSession: { id in
                guard let server = servers[id] else { throw MailRepositoryError.actionUnavailable }
                return server
            }
        )
        return (repository, store)
    }

    private func ids(_ store: InMemoryMessageStore, _ account: Account, _ mailbox: String, _ uids: [UInt32]) async throws -> [MessageID] {
        let messages = await store.messages(account: account.id, mailbox: mailbox)
        return try uids.map { uid in try #require(messages.first { $0.uid == uid }).summary.id }
    }

    @Test func markingSeveralReadSendsOneCommand() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp([(yahoo, server)])
        let targets = try await ids(store, yahoo, "INBOX", [11, 12, 13])

        try await repository.perform(.markRead, on: targets)

        // 既に既読の 13 は送らない。終わったら接続を閉じる
        let serverCalls = await server.calls
        #expect(serverCalls == ["STORE INBOX +\\Seen [11, 12]", "CLOSE"])
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 0)
        #expect(try await repository.messages(in: .unified(.inbox), filter: .unread).isEmpty)
    }

    /// できないもの (ゴミ箱のメールのアーカイブ) は飛ばして、できるものだけ動かす。
    @Test func messagesThatCannotBeArchivedAreSkipped() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp([(yahoo, server)])
        let targets = try await ids(store, yahoo, "INBOX", [11, 13]) + ids(store, yahoo, "Trash", [21])

        try await repository.perform(.archive, on: targets)

        let serverCalls = await server.calls
        #expect(serverCalls == ["MOVE INBOX -> Archive [11, 13]", "CLOSE"])
        #expect(try await repository.messages(in: .unified(.inbox), filter: .all).map(\.subject) == ["two"])
        #expect(try await repository.messages(in: .unified(.archive), filter: .all).count == 2)
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 1)
    }

    /// 違うアカウントのメールが混ざっていても、それぞれのサーバーに 1 回ずつ送る。
    @Test func mixedAccountsGoToTheirOwnServers() async throws {
        let yahooServer = await yahooServer()
        let gmailServer = await gmailServer()
        let (repository, store) = try await setUp([(yahoo, yahooServer), (gmail, gmailServer)])
        let targets = try await ids(store, yahoo, "INBOX", [11, 12]) + ids(store, gmail, "[Gmail]/All Mail", [1, 2])

        try await repository.perform(.archive, on: targets)

        let yahooServerCalls = await yahooServer.calls
        #expect(yahooServerCalls == ["MOVE INBOX -> Archive [11, 12]", "CLOSE"])
        let gmailServerCalls = await gmailServer.calls
        #expect(gmailServerCalls == ["LABELS [Gmail]/All Mail -\\Inbox [1, 2]", "CLOSE"])
        #expect(try await repository.messages(in: .unified(.inbox), filter: .all).map(\.subject) == ["three"])
    }

    /// 1 つのサーバーが断ったら、そのアカウントの分だけ元に戻して知らせる。ほかのアカウントの分は済ませる。
    @Test func aRefusalRevertsOnlyThatServersMessages() async throws {
        let yahooServer = await yahooServer()
        let gmailServer = await gmailServer()
        let (repository, store) = try await setUp([(yahoo, yahooServer), (gmail, gmailServer)])
        await yahooServer.setFailNextWrite(true)
        let targets = try await ids(store, yahoo, "INBOX", [11]) + ids(store, gmail, "[Gmail]/All Mail", [1])

        await #expect(throws: (any Error).self) {
            try await repository.perform(.moveToTrash, on: targets)
        }

        #expect(try await repository.messages(in: .unified(.trash), filter: .all).map(\.subject).sorted() == ["g1", "trashed"])
        #expect(try await repository.messages(in: .unified(.inbox), filter: .all).map(\.subject).contains("one"))
        #expect(try await store.inboxUnreadCount(account: yahoo.id) == 2)
    }

    /// 1 通だけのときは、これまでと同じ (できない操作は断る)。
    @Test func aSingleMessageKeepsTheOldBehaviour() async throws {
        let server = await yahooServer()
        let (repository, store) = try await setUp([(yahoo, server)])
        let trashed = try await ids(store, yahoo, "Trash", [21])
        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.archive, on: trashed)
        }
    }
}
