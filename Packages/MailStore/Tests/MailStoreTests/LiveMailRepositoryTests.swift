import Foundation
import Testing
@testable import MailStore

/// 保存したメールを画面に渡す窓口。仮データ (`PreviewMailRepository`) と同じ約束を守る。
@Suite struct LiveMailRepositoryTests {
    private let work = Account(id: AccountID("work"), provider: .gmail, emailAddress: "w@gmail.com", displayName: "Gmail (仕事)")
    private let yahoo = Account(id: AccountID("yahoo"), provider: .yahoo, emailAddress: "y@yahoo.example", displayName: "Yahoo!")

    private func message(
        _ id: String, account: AccountID, mailbox: MailboxRole, minutesAgo: Double, isRead: Bool = false, isStarred: Bool = false
    ) -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID(id), accountID: account, mailbox: mailbox,
                sender: Contact(name: "差出人 \(id)", address: "\(id)@example.com"),
                subject: "件名 \(id)", preview: "", date: Date(timeIntervalSince1970: 1_794_000_000 - minutesAgo * 60),
                isRead: isRead, isStarred: isStarred
            ),
            mailbox: "INBOX",
            uid: UInt32(abs(id.hashValue) % 100_000)
        )
    }

    private func repository() async throws -> (LiveMailRepository, InMemoryMessageStore) {
        let store = InMemoryMessageStore()
        try await store.upsert([
            message("w1", account: work.id, mailbox: .inbox, minutesAgo: 10),
            message("w2", account: work.id, mailbox: .inbox, minutesAgo: 30, isRead: true, isStarred: true),
            message("w3", account: work.id, mailbox: .sent, minutesAgo: 5, isRead: true),
            message("w4", account: work.id, mailbox: .drafts, minutesAgo: 1),
            message("y1", account: yahoo.id, mailbox: .inbox, minutesAgo: 20),
            message("y2", account: yahoo.id, mailbox: .inbox, minutesAgo: 40),
        ])
        // 仕事用だけ、サーバーから未読数を聞けている (保存外の古い未読を含めて 9 通)
        try await store.setInboxUnreadCount(9, account: work.id)
        let accounts = [work, yahoo]
        return (LiveMailRepository(store: store, accounts: { accounts }), store)
    }

    @Test func returnsTheAccounts() async throws {
        let (repository, _) = try await repository()
        #expect(try await repository.accounts().map(\.id) == [work.id, yahoo.id])
    }

    @Test func unifiedInboxIsNewestFirstAcrossAccounts() async throws {
        let (repository, _) = try await repository()
        let messages = try await repository.messages(in: .unified(.inbox), filter: .all)
        #expect(messages.map(\.id.rawValue) == ["w1", "y1", "w2", "y2"])
    }

    @Test func accountSelectionShowsOnlyThatAccount() async throws {
        let (repository, _) = try await repository()
        let messages = try await repository.messages(in: .account(yahoo.id, .inbox), filter: .all)
        #expect(messages.map(\.id.rawValue) == ["y1", "y2"])
    }

    @Test func filtersAndOtherFolders() async throws {
        let (repository, _) = try await repository()
        #expect(try await repository.messages(in: .unified(.inbox), filter: .unread).map(\.id.rawValue) == ["w1", "y1", "y2"])
        #expect(try await repository.messages(in: .unified(.starred), filter: .all).map(\.id.rawValue) == ["w2"])
        #expect(try await repository.messages(in: .unified(.sent), filter: .all).map(\.id.rawValue) == ["w3"])
        #expect(try await repository.messages(in: .unified(.drafts), filter: .all).map(\.id.rawValue) == ["w4"])
    }

    @Test func inboxUnreadUsesTheServerCountWhenKnown() async throws {
        let (repository, _) = try await repository()
        // 仕事用はサーバーの 9、Yahoo! はまだ聞けていないので保存分の 2
        #expect(try await repository.unreadCount(in: .account(work.id, .inbox)) == 9)
        #expect(try await repository.unreadCount(in: .account(yahoo.id, .inbox)) == 2)
        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 11)
        #expect(try await repository.unreadCount(in: .unified(.unread)) == 11)
    }

    @Test func otherFoldersCountSavedUnreadMessages() async throws {
        let (repository, _) = try await repository()
        #expect(try await repository.unreadCount(in: .unified(.drafts)) == 1)
        #expect(try await repository.unreadCount(in: .unified(.sent)) == 0)
    }

    @Test func bodyIsAPlaceholderUntilBodiesAreFetched() async throws {
        let (repository, _) = try await repository()
        let body = try await repository.body(for: MessageID("w1"))
        #expect(body.messageID == MessageID("w1"))
        #expect(!body.text.isEmpty)
        await #expect(throws: MailRepositoryError.messageNotFound(MessageID("nope"))) {
            _ = try await repository.body(for: MessageID("nope"))
        }
    }

    @Test func removedAccountsMessagesAreHidden() async throws {
        let store = InMemoryMessageStore()
        try await store.upsert([message("y1", account: yahoo.id, mailbox: .inbox, minutesAgo: 1)])
        let onlyWork = [work]
        let repository = LiveMailRepository(store: store, accounts: { onlyWork })
        #expect(try await repository.messages(in: .unified(.inbox), filter: .all).isEmpty)
        #expect(try await repository.unreadCount(in: .unified(.inbox)) == 0)
    }
}
