import Foundation
import MailStore
import Testing
@testable import CozyMail

/// メモリ上のメールに操作を反映し、呼ばれた操作を記録する。
private final class ActionSpyRepository: MailRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [MessageSummary]
    private(set) var performed: [(MessageAction, MessageID)] = []
    private let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")

    init() {
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        summaries = (1...3).map { number in
            MessageSummary(
                id: MessageID("m\(number)"), accountID: AccountID("a"), mailbox: .inbox,
                sender: Contact(name: "差出人\(number)", address: "s\(number)@example.com"),
                subject: "件名\(number)", preview: "", date: base.addingTimeInterval(Double(-number) * 60), isRead: false
            )
        }
    }

    func accounts() async throws -> [Account] { [account] }

    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        lock.withLock {
            summaries.filter { message in
                let inFolder = selection.role == .unread ? message.mailbox == .inbox && !message.isRead : message.mailbox == selection.role
                let passes = filter == .all || (filter == .unread && !message.isRead) || (filter == .starred && message.isStarred)
                return inFolder && passes
            }
        }
    }

    func unreadCount(in selection: MailboxSelection) async throws -> Int {
        lock.withLock { summaries.count { $0.mailbox == .inbox && !$0.isRead } }
    }

    func body(for id: MessageID) async throws -> MessageBody {
        MessageBody(messageID: id, to: [], text: "本文")
    }

    func attachmentData(for id: MessageID, index: Int) async throws -> Data { Data() }

    func perform(_ action: MessageAction, on id: MessageID) async throws {
        lock.withLock {
            performed.append((action, id))
            guard let index = summaries.firstIndex(where: { $0.id == id }) else { return }
            switch action {
            case .markRead: summaries[index].isRead = true
            case .markUnread: summaries[index].isRead = false
            case .star: summaries[index].isStarred = true
            case .unstar: summaries[index].isStarred = false
            case .archive: summaries[index].mailbox = .archive
            case .moveToTrash: summaries[index].mailbox = .trash
            case .markAsJunk: summaries[index].mailbox = .junk
            }
        }
    }

    var performedActions: [MessageAction] {
        lock.withLock { performed.map(\.0) }
    }
}

@MainActor @Suite struct InboxModelActionTests {
    @Test func openingAnUnreadMessageMarksOnlyThatMessageRead() async {
        let repository = ActionSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()

        // 最初のメールが自動で選ばれて開かれる
        #expect(model.selectedMessageID == MessageID("m1"))
        #expect(repository.performedActions == [.markRead])
        #expect(model.messages.first?.isRead == true)
        #expect(model.unifiedUnreadCount == 2)
    }

    /// 「未読」で絞っているとき、開いたメールを既読にしても一覧を読み直さない。
    /// 読み直すと、そのメールが消えて次が選ばれ、それも既読になり…と全部既読になってしまう。
    @Test func unreadFilterDoesNotCascadeIntoMarkingEverythingRead() async {
        let repository = ActionSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()

        // 絞り込みを変えると先頭 (m2) が選ばれて既読になる。ここまでは利用者の操作による 1 通だけ
        await model.setFilter(.unread)
        #expect(repository.performedActions.filter { $0 == .markRead }.count == 2)
        #expect(model.selectedMessageID == MessageID("m2"))
        // 既読になった m2 は一覧に残り、次の m3 は未読のまま (連鎖しない)
        #expect(model.messages.map(\.id.rawValue) == ["m2", "m3"])
        #expect(model.messages.last?.isRead == false)

        // 同じメールを選び直しても、もう一度は送らない
        await model.selectMessage(MessageID("m2"))
        #expect(repository.performedActions.filter { $0 == .markRead }.count == 2)
    }

    @Test func archiveRemovesTheMessageFromTheInbox() async {
        let repository = ActionSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()

        await model.perform(.archive)

        #expect(!model.messages.contains { $0.id == MessageID("m1") })
        #expect(model.actionError == nil)
    }

    @Test func starIsShownImmediately() async {
        let repository = ActionSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()

        await model.perform(.star)

        #expect(model.selectedMessage?.isStarred == true)
        #expect(model.canPerform(.unstar, on: model.selectedMessage))
        #expect(!model.canPerform(.star, on: model.selectedMessage))
    }

    @Test func samplesAreNeverChanged() async {
        let model = InboxModel(repository: PreviewMailRepository(), isShowingSamples: true)
        await model.load()
        let before = model.messages
        #expect(!model.canPerform(.archive, on: model.selectedMessage))
        await model.perform(.archive)
        #expect(model.actionError == nil)
        #expect(model.messages == before)
    }

    /// 右クリックのメニュー: 未読のメールには「既読にする」、受信トレイのメールは全部押せる。
    @Test func menuOffersTheActionsThatFitTheMessage() async throws {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        // m1 は開いたので既読、m2 はまだ未読
        let unread = try #require(model.messages.first { $0.id == MessageID("m2") })
        #expect(model.menuEntries(for: unread) == [
            .action(title: "既読にする", action: .markRead, isEnabled: true),
            .action(title: "スターを付ける", action: .star, isEnabled: true),
            .separator,
            .action(title: "アーカイブ", action: .archive, isEnabled: true),
            .action(title: "削除", action: .moveToTrash, isEnabled: true),
            .action(title: "迷惑メールにする", action: .markAsJunk, isEnabled: true),
        ])
        let opened = try #require(model.messages.first { $0.id == MessageID("m1") })
        #expect(model.menuEntries(for: opened).first == .action(title: "未読にする", action: .markUnread, isEnabled: true))
    }

    @Test func menuOnSamplesIsShownButNothingCanBePressed() async throws {
        let model = InboxModel(repository: PreviewMailRepository(), isShowingSamples: true)
        await model.load()
        let message = try #require(model.messages.first)
        let entries = model.menuEntries(for: message)
        #expect(entries.count == 6)
        #expect(entries.allSatisfy { entry in
            if case let .action(_, _, isEnabled) = entry { !isEnabled } else { true }
        })
    }

    // MARK: - キーボード操作 (T16)

    @Test func arrowKeysMoveTheSelectionAndStopAtTheEnds() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        #expect(model.selectedMessageID == MessageID("m1"))

        await model.selectPrevious()
        #expect(model.selectedMessageID == MessageID("m1"))
        await model.selectNext()
        #expect(model.selectedMessageID == MessageID("m2"))
        #expect(model.selectedBody?.messageID == MessageID("m2"))
        await model.selectNext()
        await model.selectNext()
        #expect(model.selectedMessageID == MessageID("m3"))
        await model.selectPrevious()
        #expect(model.selectedMessageID == MessageID("m2"))
    }

    /// アーカイブしたら、次のメールが選ばれる (先頭には戻らない)。
    @Test func archivingSelectsTheNextMessage() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        await model.selectMessage(MessageID("m2"))

        await model.perform(.archive)

        #expect(model.messages.map(\.id.rawValue) == ["m1", "m3"])
        #expect(model.selectedMessageID == MessageID("m3"))
    }

    @Test func deletingTheLastMessageSelectsTheNewLast() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        await model.selectMessage(MessageID("m3"))

        await model.perform(.moveToTrash)

        #expect(model.messages.map(\.id.rawValue) == ["m1", "m2"])
        #expect(model.selectedMessageID == MessageID("m2"))
    }

    /// 右クリックで、選んでいない行をアーカイブしても、選んでいるメールはそのまま。
    @Test func archivingAnotherRowKeepsTheSelection() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()

        await model.perform(.archive, on: MessageID("m3"))

        #expect(model.selectedMessageID == MessageID("m1"))
    }

    @Test func toggleReadAndStarFlipTheSelectedMessage() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        #expect(model.selectedMessage?.isRead == true)

        await model.toggleRead()
        #expect(model.selectedMessage?.isRead == false)
        await model.toggleRead()
        #expect(model.selectedMessage?.isRead == true)

        await model.toggleStar()
        #expect(model.selectedMessage?.isStarred == true)
        await model.toggleStar()
        #expect(model.selectedMessage?.isStarred == false)
    }

    @Test func searchShortcutAsksTheScreenToFocusTheSearchField() {
        let model = InboxModel(repository: ActionSpyRepository())
        let before = model.searchFocusRequest
        model.requestSearchFocus()
        #expect(model.searchFocusRequest == before + 1)
    }

    @Test func archiveIsOnlyOfferedForInboxMessages() async {
        let model = InboxModel(repository: ActionSpyRepository())
        await model.load()
        var sent = model.selectedMessage
        sent?.mailbox = .sent
        #expect(model.canPerform(.archive, on: model.selectedMessage))
        #expect(!model.canPerform(.archive, on: sent))
    }
}
