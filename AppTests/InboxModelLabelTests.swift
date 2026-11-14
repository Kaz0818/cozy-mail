import Foundation
import MailStore
import Testing
@testable import CozyMail

/// サイドバーの Gmail のラベル (T13)。アカウントを選んでいるときだけ、そのアカウントのラベルが出る。
@MainActor @Suite struct InboxModelLabelTests {
    private let work = Account(id: AccountID("work"), provider: .gmail, emailAddress: "me@gmail.com", displayName: "仕事用")
    private let home = Account(id: AccountID("home"), provider: .gmail, emailAddress: "home@gmail.com", displayName: "家")

    private func message(_ number: Int, _ account: Account, labels: [String], role: MailboxRole = .archive, isRead: Bool = true) -> StoredMessage {
        StoredMessage(
            summary: MessageSummary(
                id: MessageID("\(account.id.rawValue)/\(number)"),
                accountID: account.id,
                mailbox: role,
                sender: Contact(name: "", address: "s@example.com"),
                subject: "\(number)",
                preview: "",
                date: Date(timeIntervalSince1970: 1_794_000_000 + Double(number) * 60),
                isRead: isRead
            ),
            mailbox: "[Gmail]/All Mail",
            uid: UInt32(number),
            labels: labels
        )
    }

    private func loadedModel(store: InMemoryMessageStore = InMemoryMessageStore()) async throws -> InboxModel {
        await store.upsert([
            message(1, work, labels: ["\\Inbox", "仕事"], role: .inbox, isRead: false),
            message(2, work, labels: ["仕事"]),
            message(3, work, labels: ["趣味"]),
            message(4, work, labels: ["仕事"], role: .trash, isRead: false),
            message(5, home, labels: ["仕事"], isRead: false),
        ])
        await store.setLabels(["仕事", "趣味"], account: work.id)
        await store.setLabels(["仕事"], account: home.id)
        let accounts = [work, home]
        let model = InboxModel(repository: LiveMailRepository(store: store, accounts: { accounts }))
        await model.load()
        return model
    }

    @Test func labelsAppearOnlyWhileAnAccountIsSelected() async throws {
        let model = try await loadedModel()
        #expect(model.labels.isEmpty)

        await model.select(.account(work.id, .inbox))
        #expect(model.labels.map(\.name) == ["仕事", "趣味"])
        // 未読数: ゴミ箱のメールは数えない
        #expect(model.labels.map(\.unreadCount) == [1, 0])

        await model.select(.account(home.id, .archive))
        #expect(model.labels.map(\.name) == ["仕事"])

        await model.select(.unified(.inbox))
        #expect(model.labels.isEmpty)
    }

    @Test func selectingALabelShowsThatAccountsMailWithTheLabel() async throws {
        let model = try await loadedModel()
        await model.select(.account(work.id, .inbox))

        await model.select(.label(work.id, "仕事"))
        // 新しい順。ゴミ箱のメールと、別のアカウントのメールは出ない
        #expect(model.messages.map(\.id.rawValue) == ["work/2", "work/1"])
        #expect(model.title == "仕事")
        // ラベルを開いている間も、そのアカウントのラベルは出たまま
        #expect(model.labels.map(\.name) == ["仕事", "趣味"])
    }

    /// Gmail でラベルを消したあとの同期で、開いていたラベルがなくなったら、そのアカウントの受信トレイに戻る。
    @Test func aLabelRemovedInGmailFallsBackToTheAccountsInbox() async throws {
        let store = InMemoryMessageStore()
        let model = try await loadedModel(store: store)
        await model.select(.label(work.id, "趣味"))

        await store.setLabels(["仕事"], account: work.id)
        await model.load()

        #expect(model.selection == .account(work.id, .inbox))
        #expect(model.labels.map(\.name) == ["仕事"])
    }
}
