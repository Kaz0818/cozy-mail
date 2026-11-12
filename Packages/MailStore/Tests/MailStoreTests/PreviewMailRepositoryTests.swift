import Foundation
import Testing
@testable import MailStore

@Suite struct PreviewMailRepositoryTests {
    let repository = PreviewMailRepository()

    @Test func returnsTheFourMockupAccountsInOrder() async throws {
        let accounts = try await repository.accounts()
        #expect(accounts.map(\.displayName) == ["Gmail (仕事)", "Gmail (プライベート)", "Gmail (副業)", "Yahoo!メール"])
        #expect(accounts.map(\.provider) == [.gmail, .gmail, .gmail, .yahoo])
    }

    @Test func unreadCountsPerAccountMatchTheMockup() async throws {
        let accounts = try await repository.accounts()
        var counts: [String: Int] = [:]
        for account in accounts {
            counts[account.displayName] = try await repository.unreadCount(in: .account(account.id, .inbox))
        }
        #expect(counts == ["Gmail (仕事)": 12, "Gmail (プライベート)": 3, "Gmail (副業)": 0, "Yahoo!メール": 7])
    }

    @Test func unifiedInboxHas22Unread() async throws {
        let inbox = try await repository.unreadCount(in: .unified(.inbox))
        let unread = try await repository.unreadCount(in: .unified(.unread))
        #expect(inbox == 22)
        #expect(unread == 22)
    }

    @Test func draftsFolderHasTwoMessages() async throws {
        let drafts = try await repository.messages(in: .unified(.drafts), filter: .all)
        #expect(drafts.count == 2)
    }

    @Test func unifiedInboxStartsWithTheSixMockupMessagesNewestFirst() async throws {
        let messages = try await repository.messages(in: .unified(.inbox), filter: .all)
        #expect(messages.prefix(6).map(\.sender.name) == [
            "山田 さくら", "Google", "田中 健一", "Yahoo!ショッピング", "Apple", "プロジェクトチーム",
        ])
        let dates = messages.map(\.date)
        #expect(dates == dates.sorted(by: >))
    }

    @Test func unreadFilterReturnsOnlyUnreadMessages() async throws {
        let unread = try await repository.messages(in: .unified(.inbox), filter: .unread)
        #expect(unread.count == 22)
        #expect(unread.allSatisfy { !$0.isRead })
    }

    @Test func starredFilterReturnsOnlyStarredMessages() async throws {
        let starred = try await repository.messages(in: .unified(.inbox), filter: .starred)
        #expect(starred.allSatisfy { $0.isStarred })
    }

    @Test func accountSelectionReturnsOnlyThatAccountsMessages() async throws {
        let accounts = try await repository.accounts()
        let yahoo = try #require(accounts.last)
        let messages = try await repository.messages(in: .account(yahoo.id, .inbox), filter: .all)
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { $0.accountID == yahoo.id })
    }

    @Test func firstMessageBodyHasTheProposalAttachment() async throws {
        let messages = try await repository.messages(in: .unified(.inbox), filter: .all)
        let first = try #require(messages.first)
        let body = try await repository.body(for: first.id)
        #expect(body.text.hasPrefix("お疲れさまです。"))
        #expect(body.attachments.map(\.filename) == ["企画書（Ver.2）.pdf"])
        #expect(body.attachments.first?.byteCount == 4_800_000)
    }
}
