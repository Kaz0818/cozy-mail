import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 検索欄 (T19)。言葉を入れると、迷惑メールとゴミ箱を除くすべてのフォルダから探して一覧に出す。
@MainActor @Suite struct InboxModelSearchTests {
    private let work = Account(id: AccountID("work"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "仕事用")

    private func message(_ id: String, _ role: MailboxRole, subject: String, minutesAgo: Double, isRead: Bool = true) -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID(id), accountID: work.id, mailbox: role,
                sender: Contact(name: "", address: "\(id)@example.com"),
                subject: subject, preview: "", date: Date(timeIntervalSince1970: 1_794_000_000 - minutesAgo * 60), isRead: isRead
            ),
            mailbox: role.rawValue, uid: 1
        )
    }

    private func loadedModel() async throws -> InboxModel {
        let store = InMemoryMessageStore()
        await store.upsert([
            message("inbox", .inbox, subject: "請求書のお知らせ", minutesAgo: 30, isRead: false),
            message("sent", .sent, subject: "Re: 請求書", minutesAgo: 10),
            message("trash", .trash, subject: "請求書 (消した)", minutesAgo: 1),
            message("other", .inbox, subject: "会議", minutesAgo: 2),
        ])
        let accounts = [work]
        let model = InboxModel(repository: LiveMailRepository(store: store, accounts: { accounts }))
        await model.load()
        return model
    }

    @Test func searchingShowsMatchesFromEveryFolder() async throws {
        let model = try await loadedModel()

        await model.search("請求書")

        #expect(model.isSearching)
        #expect(model.messages.map(\.id.rawValue) == ["sent", "inbox"])
        #expect(model.title == "検索")
        #expect(model.subtitle == "「請求書」・2件")
    }

    /// 打っている途中で一番上のメールを勝手に開くと、読んでいない未読メールがサーバーで既読になってしまう。
    /// 検索中は、開いていたメールが結果にないとき、何も開かない。
    @Test func searchingDoesNotOpenOrMarkReadTheTopResult() async throws {
        let store = InMemoryMessageStore()
        await store.upsert([
            message("unread", .inbox, subject: "請求書のお知らせ", minutesAgo: 1, isRead: false),
            message("other", .inbox, subject: "会議", minutesAgo: 2),
        ])
        let accounts = [work]
        let model = InboxModel(repository: LiveMailRepository(store: store, accounts: { accounts }))
        await model.load()
        await model.selectMessage(MessageID("other"))

        await model.search("請求")

        #expect(model.messages.map(\.id.rawValue) == ["unread"])
        #expect(model.selectedMessageID == nil)
        #expect(await store.message(id: MessageID("unread"))?.summary.isRead == false)
    }

    /// 開いていたメールが結果に入っていれば、そのまま開いておく。
    @Test func theOpenMailStaysOpenWhenItIsInTheResults() async throws {
        let model = try await loadedModel()
        await model.selectMessage(MessageID("inbox"))

        await model.search("請求書")

        #expect(model.selectedMessageID == MessageID("inbox"))
    }

    @Test func theUnreadFilterAlsoNarrowsTheResults() async throws {
        let model = try await loadedModel()
        await model.search("請求書")

        await model.setFilter(.unread)

        #expect(model.messages.map(\.id.rawValue) == ["inbox"])
    }

    @Test func clearingTheSearchGoesBackToTheFolder() async throws {
        let model = try await loadedModel()
        await model.search("請求書")

        await model.search("  ")

        #expect(!model.isSearching)
        #expect(model.title == "受信トレイ")
        #expect(model.messages.map(\.id.rawValue) == ["other", "inbox"])
    }

    /// 検索中にサイドバーで (同じものでも) フォルダを選ぶと、検索をやめてそのフォルダを出す。
    @Test func choosingAFolderEndsTheSearch() async throws {
        let model = try await loadedModel()
        await model.search("請求書")

        await model.select(.unified(.inbox))

        #expect(model.searchText.isEmpty)
        #expect(model.messages.map(\.id.rawValue) == ["other", "inbox"])
    }

    @Test func nothingFoundShowsAnEmptyList() async throws {
        let model = try await loadedModel()

        await model.search("見つからない言葉")

        #expect(model.messages.isEmpty)
        #expect(model.selectedMessageID == nil)
        #expect(model.subtitle == "「見つからない言葉」・0件")
    }
}
