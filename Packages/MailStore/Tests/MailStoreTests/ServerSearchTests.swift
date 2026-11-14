import Foundation
import MailCore
import Testing
@testable import MailStore

/// サーバー側の検索 (T27、US-10)。Mac に保存していない古いメールや、本文の言葉でも見つかる。
/// 見つけたメールは保存先に入れない (入れると、次の同期で印を取り直す範囲が何年分にも広がるため)。
@Suite struct ServerSearchTests {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "me@yahoo.example", displayName: "Yahoo!")
    private let gmail = Account(id: AccountID("gmail"), provider: .gmail, emailAddress: "me@gmail.example", displayName: "Gmail")

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    /// 受信トレイに、最近のメール (同期で保存される) と、1 年前のメール (保存されない) がある。
    private func yahooServer() async -> FakeMailServer {
        let server = FakeMailServer()
        await server.addFolder("INBOX", uidValidity: 7)
        await server.addFolder("Sent", specialUse: .sent)
        await server.addFolder("Trash", specialUse: .trash)
        await server.add(.init(uid: 1, date: daysAgo(365), subject: "去年の請求書", from: "shop@example.com", body: "お支払いのお願い"), to: "INBOX")
        await server.add(.init(uid: 2, date: daysAgo(400), subject: "旅行の予定", from: "friend@example.com", body: "請求書は別に送ります"), to: "INBOX")
        await server.add(.init(uid: 3, date: daysAgo(2), subject: "今月の請求書", from: "shop@example.com"), to: "INBOX")
        await server.add(.init(uid: 4, date: daysAgo(3), subject: "近況", from: "friend@example.com", body: "請求書の件、了解です"), to: "INBOX")
        await server.add(.init(uid: 9, date: daysAgo(500), subject: "捨てた請求書", from: "shop@example.com"), to: "Trash")
        return server
    }

    private func setUp(
        _ servers: [AccountID: FakeMailServer], accounts: [Account], limit: Int = 50
    ) async throws -> (any MailRepository, InMemoryMessageStore, ServerSearchCache) {
        let store = InMemoryMessageStore()
        let now = now
        // サーバーがないアカウント (つながらない) は同期しない
        for account in accounts {
            guard let server = servers[account.id] else { continue }
            _ = try await SyncEngine(store: store, now: { now }).sync(account: account, session: server)
        }
        for server in servers.values { await server.clearCalls() }
        let cache = ServerSearchCache()
        let accountsCopy = accounts
        let opener: @Sendable (AccountID) async throws -> any MailServerSession = { id in
            guard let server = servers[id] else { throw MailRepositoryError.actionUnavailable }
            return server
        }
        let live = LiveMailRepository(store: store, accounts: { accountsCopy }, openSession: opener)
        let repository = ServerSearchRepository(
            base: live, store: store, accounts: { accountsCopy }, openSession: opener, cache: cache, limitPerFolder: limit
        )
        return (repository, store, cache)
    }

    /// 古いメールも本文の言葉でも見つかる。保存しているメールは、保存している形 (ふつうの番号) で返す。ゴミ箱は探さない。
    @Test func findsOldMessagesAndWordsInTheBody() async throws {
        let server = await yahooServer()
        let (repository, store, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        #expect(try await store.allSummaries().count == 2)  // 最近の 2 通だけ保存している

        let found = try await repository.searchServer("請求書")
        #expect(found.map(\.subject) == ["今月の請求書", "近況", "去年の請求書", "旅行の予定"])  // 新しい順
        let old = try #require(found.first { $0.subject == "去年の請求書" })
        #expect(ServerMessage.isServerOnly(old.id))
        #expect(old.mailbox == .inbox && old.accountID == yahoo.id)
        let recent = try #require(found.first { $0.subject == "近況" })
        #expect(!ServerMessage.isServerOnly(recent.id))
        #expect(try await store.message(id: recent.id) != nil)

        let calls = await server.calls
        #expect(calls.contains("SEARCH TEXT INBOX 請求書"))
        #expect(!calls.contains { $0.hasPrefix("SEARCH TEXT Trash") })
        // 保存しているメールの見出しは取り直さない
        #expect(calls.contains("FETCH INBOX [1, 2]"))
        // 見つけたメールは保存先に入れない
        #expect(try await store.allSummaries().count == 2)
    }

    /// 見つけた古いメールを開ける (本文はサーバーから取る。2 回目は取らない)。返信もできる。
    @Test func oldMessagesCanBeOpenedAndRepliedTo() async throws {
        let server = await yahooServer()
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        let old = try #require(try await repository.searchServer("支払い").first)

        let body = try await repository.body(for: old.id)
        #expect(body.text.contains("お支払いのお願い"))
        _ = try await repository.body(for: old.id)
        let fetches = await server.calls.filter { $0.hasPrefix("BODY") }
        #expect(fetches == ["BODY INBOX 1"])

        let source = try await repository.replySource(for: old.id)
        #expect(source.accountID == yahoo.id)
        #expect(source.subject == "去年の請求書")
    }

    /// 見つけた古いメールは、整理の操作 (既読・アーカイブなど) ができない (Mac に保存していないため)。
    @Test func serverOnlyMessagesCannotBeChanged() async throws {
        let server = await yahooServer()
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        let old = try #require(try await repository.searchServer("支払い").first)
        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.markRead, on: old.id)
        }
        let writes = await server.calls.filter { $0.hasPrefix("STORE") || $0.hasPrefix("MOVE") || $0.hasPrefix("LABELS") }
        #expect(writes.isEmpty)
    }

    /// Gmail は「すべてのメール」で探す (同期と同じ番号になる)。役割はラベルで決める。
    @Test func gmailSearchesAllMail() async throws {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        await server.addFolder("[Gmail]/All Mail", specialUse: .all)
        await server.addFolder("[Gmail]/Spam", specialUse: .junk)
        await server.addFolder("[Gmail]/Trash", specialUse: .trash)
        await server.add(.init(uid: 70, date: daysAgo(900), subject: "Old invoice", from: "a@example.com",
                               labels: ["\\Sent"]), to: "[Gmail]/All Mail")
        await server.add(.init(uid: 71, date: daysAgo(10), subject: "Invoice again", from: "a@example.com",
                               labels: ["\\Inbox"]), to: "[Gmail]/All Mail")
        await server.add(.init(uid: 5, date: daysAgo(800), subject: "Spam invoice", from: "x@example.com"), to: "[Gmail]/Spam")
        let (repository, _, _) = try await setUp([gmail.id: server], accounts: [gmail])

        let found = try await repository.searchServer("invoice")
        #expect(found.map(\.subject) == ["Invoice again", "Old invoice"])
        #expect(found.last?.mailbox == .sent)
        let calls = await server.calls
        #expect(calls.filter { $0.hasPrefix("SEARCH TEXT") } == ["SEARCH TEXT [Gmail]/All Mail invoice"])
    }

    /// 1 つのフォルダから取るのは、新しい方から決めた数まで (何千通も見つかったとき、全部の見出しを取らない)。
    @Test func onlyTheNewestMatchesAreFetched() async throws {
        let server = FakeMailServer()
        await server.addFolder("INBOX")
        for uid in UInt32(1)...20 {
            await server.add(.init(uid: uid, date: daysAgo(Double(400 - uid)), subject: "news \(uid)", from: "n@example.com"), to: "INBOX")
        }
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo], limit: 5)
        let found = try await repository.searchServer("news")
        #expect(found.map(\.subject) == (16...20).reversed().map { "news \($0)" })
        #expect(await server.calls.contains("FETCH INBOX [16, 17, 18, 19, 20]"))
    }

    /// つながらないアカウントがあっても、ほかのアカウントの結果は出す。全部だめなら、失敗を知らせる。
    @Test func oneFailingAccountDoesNotHideTheOthers() async throws {
        let server = await yahooServer()
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo, gmail])
        let found = try await repository.searchServer("支払い")
        #expect(found.map(\.subject) == ["去年の請求書"])

        let (lonely, _, _) = try await setUp([:], accounts: [gmail])
        await #expect(throws: MailRepositoryError.actionUnavailable) {
            try await lonely.searchServer("支払い")
        }
    }

    /// アプリでは下書きの窓口 (T23a) が外側にあるので、そこを通しても探せて開ける。
    @Test func worksThroughTheDraftsRepository() async throws {
        let server = await yahooServer()
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        let drafts = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SS-\(UUID().uuidString)"))
        let outer = DraftsMergingRepository(base: repository, drafts: drafts)
        let old = try #require(try await outer.searchServer("支払い").first)
        #expect(old.subject == "去年の請求書")
        #expect(try await outer.body(for: old.id).text.contains("お支払いのお願い"))
        #expect(try await outer.replySource(for: old.id).subject == "去年の請求書")
    }

    /// 空白だけなら、サーバーにつながない。
    @Test func blankTextDoesNotConnect() async throws {
        let server = await yahooServer()
        let (repository, _, _) = try await setUp([yahoo.id: server], accounts: [yahoo])
        #expect(try await repository.searchServer("  ").isEmpty)
        #expect(await server.calls.isEmpty)
    }

    /// 新しく探すと、前に見つけたメールは忘れる (覚えておくものが増え続けないように)。
    @Test func aNewSearchForgetsTheOldResults() async throws {
        let server = await yahooServer()
        let (repository, _, cache) = try await setUp([yahoo.id: server], accounts: [yahoo])
        let old = try #require(try await repository.searchServer("支払い").first)
        #expect(await cache.message(old.id) != nil)
        _ = try await repository.searchServer("旅行")
        #expect(await cache.message(old.id) == nil)
        await #expect(throws: MailRepositoryError.messageNotFound(old.id)) {
            _ = try await repository.body(for: old.id)
        }
    }
}
