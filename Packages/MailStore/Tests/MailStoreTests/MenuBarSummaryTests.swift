import Foundation
import Testing
@testable import MailStore

/// メニューバーに出す中身 (T21): 未読数と、最近の未読メール。
@Suite struct MenuBarSummaryTests {
    private let account = AccountID("a")

    private func message(_ n: Int, read: Bool = false, subject: String = "件名") -> MessageSummary {
        MessageSummary(
            id: MessageID("a/\(n)"), accountID: account, mailbox: .inbox,
            sender: Contact(name: "差出人\(n)", address: "s\(n)@example.com"),
            subject: subject, preview: "", date: Date(timeIntervalSince1970: 1_794_000_000 + Double(n)), isRead: read
        )
    }

    @Test func showsTheUnreadCountLikeTheDock() {
        let summary = MenuBarSummary(unreadCount: 12, unreadMessages: [], isShowingSamples: false)
        #expect(summary.countLabel == "12")
        #expect(MenuBarSummary(unreadCount: 0, unreadMessages: [], isShowingSamples: false).countLabel == nil)
        #expect(MenuBarSummary(unreadCount: 1200, unreadMessages: [], isShowingSamples: false).countLabel == "999+")
    }

    @Test func samplesShowNothing() {
        let summary = MenuBarSummary(unreadCount: 22, unreadMessages: [message(1)], isShowingSamples: true)
        #expect(summary.countLabel == nil)
        #expect(summary.recent.isEmpty)
    }

    @Test func listsTheFiveNewestUnreadMessages() {
        let messages = (1...8).map { message($0) } + [message(9, read: true)]
        let summary = MenuBarSummary(unreadCount: 8, unreadMessages: messages, isShowingSamples: false)
        #expect(summary.recent.map(\.id) == [8, 7, 6, 5, 4].map { MessageID("a/\($0)") })
        #expect(summary.recent.first?.sender == "差出人8")
    }

    @Test func emptySubjectsAreFilledIn() {
        let summary = MenuBarSummary(unreadCount: 1, unreadMessages: [message(1, subject: " ")], isShowingSamples: false)
        #expect(summary.recent.first?.subject == "(件名なし)")
    }
}
