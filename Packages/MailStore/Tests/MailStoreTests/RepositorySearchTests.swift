import Foundation
import Testing
@testable import MailStore

/// 窓口の検索 (T19)。登録中のアカウントの、迷惑メールとゴミ箱を除くすべてのフォルダから探す。
@Suite struct RepositorySearchTests {
    private let work = Account(id: AccountID("work"), provider: .gmail, emailAddress: "w@gmail.com", displayName: "仕事")
    private let removed = AccountID("removed")

    private func message(_ id: String, _ account: AccountID, _ role: MailboxRole, subject: String, minutesAgo: Double, isRead: Bool = true) -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID(id), accountID: account, mailbox: role,
                sender: Contact(name: "", address: "\(id)@example.com"),
                subject: subject, preview: "", date: Date(timeIntervalSince1970: 1_794_000_000 - minutesAgo * 60), isRead: isRead
            ),
            mailbox: role.rawValue, uid: 1
        )
    }

    @Test func liveRepositorySearchesEveryFolderButJunkAndTrash() async throws {
        let store = InMemoryMessageStore()
        await store.upsert([
            message("inbox", work.id, .inbox, subject: "請求書のお知らせ", minutesAgo: 30, isRead: false),
            message("sent", work.id, .sent, subject: "Re: 請求書", minutesAgo: 10),
            message("archive", work.id, .archive, subject: "古い請求書", minutesAgo: 60),
            message("junk", work.id, .junk, subject: "請求書 (怪しい)", minutesAgo: 5),
            message("trash", work.id, .trash, subject: "請求書 (消した)", minutesAgo: 1),
            message("other", work.id, .inbox, subject: "会議", minutesAgo: 2),
            message("removed", removed, .inbox, subject: "請求書 (消したアカウント)", minutesAgo: 3),
        ])
        let repository = LiveMailRepository(store: store, accounts: { [work] })

        let all = try await repository.search("請求書", filter: .all)
        #expect(all.map(\.id.rawValue) == ["sent", "inbox", "archive"])
        let unread = try await repository.search("請求書", filter: .unread)
        #expect(unread.map(\.id.rawValue) == ["inbox"])
        let none = try await repository.search("見つからない", filter: .all)
        #expect(none.isEmpty)
    }

    @Test func previewRepositorySearchesTooSoTheScreenCanBeTried() async throws {
        let repository = PreviewMailRepository()
        let anyMessage = try #require(try await repository.messages(in: .unified(.inbox), filter: .all).first)
        let word = String(anyMessage.subject.prefix(4))

        let found = try await repository.search(word, filter: .all)
        #expect(found.contains { $0.id == anyMessage.id })
        #expect(found.allSatisfy { $0.mailbox != .junk && $0.mailbox != .trash })
    }
}
