import Foundation
import Testing
@testable import MailStore

/// 新着の通知に何を出すか (T20b)。画面 (UserNotifications) とは分けてある。
@Suite struct NewMailNotifierTests {
    private let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "Gmail (仕事)")

    private func message(_ n: Int, subject: String = "件名", name: String = "田中 健一", read: Bool = false,
                         mailbox: MailboxRole = .inbox) -> MessageSummary {
        MessageSummary(
            id: MessageID("a/\(n)"), accountID: account.id, mailbox: mailbox,
            sender: Contact(name: name, address: "t\(n)@example.com"),
            subject: subject, preview: "本文の書き出し \(n)", date: Date(timeIntervalSince1970: 1_794_000_000 + Double(n)), isRead: read
        )
    }

    @Test func oneAlertPerMessageWithSenderAndSubject() {
        let alerts = NewMailNotifier.alerts(for: [message(1, subject: "会議の件")], accounts: [account])
        #expect(alerts == [NewMailAlert(
            title: "田中 健一", subtitle: "会議の件", body: "本文の書き出し 1",
            messageID: MessageID("a/1"), accountName: "Gmail (仕事)"
        )])
    }

    @Test func newestComesFirst() {
        let alerts = NewMailNotifier.alerts(for: [message(1), message(3), message(2)], accounts: [account])
        #expect(alerts.map(\.messageID) == [MessageID("a/3"), MessageID("a/2"), MessageID("a/1")])
    }

    @Test func emptySubjectsAndNamesAreFilledIn() {
        let alert = NewMailNotifier.alerts(for: [message(1, subject: "  ", name: "")], accounts: [account]).first
        #expect(alert?.title == "t1@example.com")
        #expect(alert?.subtitle == "(件名なし)")
    }

    /// 既読・受信トレイ以外 (迷惑メールなど) は知らせない。
    @Test func skipsReadAndNonInboxMail() {
        let alerts = NewMailNotifier.alerts(
            for: [message(1, read: true), message(2, mailbox: .junk), message(3, mailbox: .archive)], accounts: [account]
        )
        #expect(alerts.isEmpty)
    }

    /// 4 通以上は 1 つにまとめる (通知があふれないように)。
    @Test func fourOrMoreAreSummarised() {
        let messages = (1...5).map { message($0, name: "差出人\($0)") }
        let alerts = NewMailNotifier.alerts(for: messages, accounts: [account])
        #expect(alerts.count == 1)
        #expect(alerts.first?.title == "5 件の新着メール")
        #expect(alerts.first?.subtitle == "Gmail (仕事)")
        #expect(alerts.first?.body == "差出人5、差出人4、差出人3 ほか")
        #expect(alerts.first?.messageID == nil)
    }

    @Test func threeAreShownOneByOne() {
        #expect(NewMailNotifier.alerts(for: (1...3).map { message($0) }, accounts: [account]).count == 3)
    }

    @Test func nothingNewMeansNoAlerts() {
        #expect(NewMailNotifier.alerts(for: [], accounts: [account]).isEmpty)
    }
}
