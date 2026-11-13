import Foundation
import MailStore
import Testing
@testable import CozyMail

@MainActor @Suite struct InboxModelTests {
    private func loadedModel() async -> InboxModel {
        let model = InboxModel(repository: PreviewMailRepository())
        await model.load()
        return model
    }

    @Test func loadsAccountsWithUnreadCountsLikeTheMockup() async {
        let model = await loadedModel()
        #expect(model.accounts.map(\.account.displayName) == ["Gmail (仕事)", "Gmail (プライベート)", "Gmail (副業)", "Yahoo!メール"])
        #expect(model.accounts.map(\.unreadCount) == [12, 3, 0, 7])
    }

    @Test func folderBadgesMatchTheMockup() async {
        let model = await loadedModel()
        let badges = Dictionary(uniqueKeysWithValues: model.folders.map { ($0.role, $0.badge) })
        #expect(badges[.inbox] == 22)
        #expect(badges[.unread] == 22)
        #expect(badges[.drafts] == 2)
        #expect(badges[.sent] == 0)
    }

    @Test func startsOnTheUnifiedInboxWithTheFirstMessageSelected() async {
        let model = await loadedModel()
        #expect(model.selection == .unified(.inbox))
        #expect(model.title == "受信トレイ")
        #expect(model.subtitle == "すべてのアカウント・22件の未読")
        #expect(model.selectedMessage?.subject == "企画のご提案について")
        #expect(model.selectedBody?.attachments.count == 1)
    }

    @Test func selectingAnAccountShowsOnlyItsMessages() async throws {
        let model = await loadedModel()
        let yahoo = try #require(model.accounts.last?.account)
        await model.select(.account(yahoo.id, .inbox))
        #expect(!model.messages.isEmpty)
        #expect(model.messages.allSatisfy { $0.accountID == yahoo.id })
        #expect(model.subtitle == "Yahoo!メール・7件の未読")
    }

    @Test func unreadFilterHidesReadMessages() async {
        let model = await loadedModel()
        await model.setFilter(.unread)
        #expect(model.messages.count == 22)
        #expect(model.messages.allSatisfy { !$0.isRead })
    }

    @Test func selectingAMessageLoadsItsBody() async throws {
        let model = await loadedModel()
        let second = try #require(model.messages.dropFirst().first)
        await model.selectMessage(second.id)
        #expect(model.selectedMessage?.id == second.id)
        #expect(model.selectedBody?.messageID == second.id)
    }

    @Test func accountNameLookupForRows() async throws {
        let model = await loadedModel()
        let first = try #require(model.messages.first)
        #expect(model.accountName(for: first) == "Gmail (仕事)")
    }
}

@Suite struct MailDateTextTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 18))!
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func listShowsTimeForTodayYesterdayForYesterdayAndDateOtherwise() {
        #expect(MailDateText.list(date(12, 16, 24), now: now, calendar: calendar) == "16:24")
        #expect(MailDateText.list(date(11, 9, 0), now: now, calendar: calendar) == "昨日")
        #expect(MailDateText.list(date(3, 9, 0), now: now, calendar: calendar) == "11/3")
        #expect(MailDateText.list(date(3, 9, 0, year: 2025), now: now, calendar: calendar) == "2025/11/3")
    }

    @Test func readerShowsDayAndTime() {
        #expect(MailDateText.reader(date(12, 16, 24), now: now, calendar: calendar) == "今日 16:24")
        #expect(MailDateText.reader(date(11, 9, 5), now: now, calendar: calendar) == "昨日 9:05")
        #expect(MailDateText.reader(date(3, 9, 5), now: now, calendar: calendar) == "11月3日 9:05")
    }

    @Test func avatarInitials() {
        #expect(AvatarView.initials(for: "山田 さくら") == "山田")
        #expect(AvatarView.initials(for: "Google") == "G")
        #expect(AvatarView.initials(for: "Yahoo!ショッピング") == "Y")
        #expect(AvatarView.initials(for: "プロジェクトチーム") == "プロ")
        #expect(AvatarView.initials(for: "") == "?")
    }
}
