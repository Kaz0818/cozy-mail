import Foundation
import MailStore
import Testing
@testable import CozyMail

/// まとめての操作を記録する窓口。メモリ上の 5 通のメールに反映する (m4 だけ既読でスター付き)。
private final class BulkSpyRepository: MailRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [MessageSummary]
    private var batchLog: [(MessageAction, [MessageID])] = []
    private let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")

    init() {
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        // 型を調べるのに時間がかからないよう、式を小さく分ける (CI のコンパイラが諦めたため)
        var list: [MessageSummary] = []
        for number in 1...5 {
            let date: Date = base.addingTimeInterval(Double(-number) * 60)
            let sender = Contact(name: "差出人\(number)", address: "s\(number)@example.com")
            let isFourth: Bool = number == 4
            list.append(MessageSummary(
                id: MessageID("m\(number)"), accountID: AccountID("a"), mailbox: .inbox, sender: sender,
                subject: "件名\(number)", preview: "", date: date, isRead: isFourth, isStarred: isFourth
            ))
        }
        summaries = list
    }

    var batches: [(MessageAction, [MessageID])] { lock.withLock { batchLog } }

    func accounts() async throws -> [Account] { [account] }

    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        lock.withLock { summaries.filter { $0.mailbox == selection.role } }
    }

    func unreadCount(in selection: MailboxSelection) async throws -> Int {
        lock.withLock { summaries.count { $0.mailbox == .inbox && !$0.isRead } }
    }

    func body(for id: MessageID) async throws -> MessageBody {
        MessageBody(messageID: id, to: [], text: "本文")
    }

    func attachmentData(for id: MessageID, index: Int) async throws -> Data { Data() }

    func perform(_ action: MessageAction, on id: MessageID) async throws {
        lock.withLock { apply(action, to: id) }
    }

    func perform(_ action: MessageAction, on ids: [MessageID]) async throws {
        lock.withLock {
            batchLog.append((action, ids))
            for id in ids { apply(action, to: id) }
        }
    }

    private func apply(_ action: MessageAction, to id: MessageID) {
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

/// 複数のメールを選んでまとめて操作する (T26、US-17)。
@MainActor @Suite struct InboxModelMultiSelectTests {
    private func ids(_ numbers: Int...) -> Set<MessageID> {
        Set(numbers.map { MessageID("m\($0)") })
    }

    private func loaded() async -> (InboxModel, BulkSpyRepository) {
        let repository = BulkSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()  // m1 が選ばれて開かれる
        return (model, repository)
    }

    /// ⌘ + クリックで足す・外す。1 通に戻ったら、ふつうの選び方に戻る。
    @Test func commandClickAddsAndRemoves() async {
        let (model, _) = await loaded()
        #expect(!model.isMultiSelecting)

        await model.toggleSelection(MessageID("m3"))
        #expect(model.selectedIDs == ids(1, 3))
        #expect(model.isMultiSelecting)
        #expect(model.isSelected(MessageID("m3")) && model.isSelected(MessageID("m1")))
        #expect(!model.isSelected(MessageID("m2")))

        await model.toggleSelection(MessageID("m1"))
        #expect(!model.isMultiSelecting)
        #expect(model.selectedMessageID == MessageID("m3"))
        #expect(model.selectedBody?.messageID == MessageID("m3"))
    }

    /// ⇧ + クリックで、選んでいたメールからそこまでをまとめて選ぶ。
    @Test func shiftClickSelectsARange() async {
        let (model, _) = await loaded()
        await model.extendSelection(to: MessageID("m4"))
        #expect(model.selectedIDs == ids(1, 2, 3, 4))
    }

    @Test func selectAllSelectsEveryMessage() async {
        let (model, _) = await loaded()
        model.selectAll()
        #expect(model.selectedIDs == ids(1, 2, 3, 4, 5))
    }

    /// まとめてアーカイブすると、窓口へは 1 回で頼む。そのあとは、残ったメールを 1 通選ぶ。
    @Test func archivingTheSelectionIsOneRequest() async {
        let (model, repository) = await loaded()
        await model.toggleSelection(MessageID("m2"))
        await model.perform(.archive)

        #expect(repository.batches.map(\.0) == [.archive])
        #expect(Set(repository.batches.first?.1 ?? []) == ids(1, 2))
        #expect(model.messages.map(\.id) == [MessageID("m3"), MessageID("m4"), MessageID("m5")])
        #expect(!model.isMultiSelecting)
        #expect(model.selectedMessageID == MessageID("m3"))
    }

    /// 既読・スターは、できるメールだけに頼み、選んだままにする。
    @Test func markingTheSelectionReadKeepsTheSelection() async {
        let (model, repository) = await loaded()
        model.selectAll()
        #expect(model.readToggleAction == .markRead)  // 未読が混ざっている
        await model.toggleRead()

        // m1 (開いて既読) と m4 (既読) には頼まない
        #expect(Set(repository.batches.first?.1 ?? []) == ids(2, 3, 5))
        #expect(model.messages.allSatisfy { $0.isRead })
        #expect(model.selectedIDs == ids(1, 2, 3, 4, 5))
        #expect(model.readToggleAction == .markUnread)
        #expect(model.unifiedUnreadCount == 0)
    }

    @Test func starToggleStarsWhenAnyIsUnstarred() async {
        let (model, repository) = await loaded()
        await model.toggleSelection(MessageID("m4"))
        #expect(model.starToggleAction == .star)
        await model.toggleStar()
        #expect(repository.batches.map(\.1) == [[MessageID("m1")]])
        #expect(model.starToggleAction == .unstar)
    }

    /// 選んだ行の右クリックは、選んだすべてに効く。選んでいない行の右クリックは、その行だけ。
    @Test func rightClickActsOnTheSelectionOnlyWhenTheRowIsSelected() async {
        let (model, repository) = await loaded()
        await model.toggleSelection(MessageID("m2"))

        await model.perform(.star, on: MessageID("m2"))
        #expect(Set(repository.batches.last?.1 ?? []) == ids(1, 2))

        await model.perform(.star, on: MessageID("m5"))
        #expect(repository.batches.count == 1)  // m5 は 1 通だけの操作
        #expect(model.messages.first { $0.id == MessageID("m5") }?.isStarred == true)
    }

    @Test func menuAndButtonsLookAtTheWholeSelection() async {
        let (model, _) = await loaded()
        await model.toggleSelection(MessageID("m4"))
        #expect(model.canPerformOnSelection(.markUnread))  // m1 も m4 も既読
        #expect(!model.canPerformOnSelection(.markRead))
        #expect(model.canPerformOnSelection(.archive))
        let titles = model.menuEntries(for: model.messages[0]).compactMap { entry -> String? in
            if case let .action(title, _, _) = entry { return title }
            return nil
        }
        #expect(titles.contains("未読にする") && titles.contains("スターを付ける"))
    }

    /// ↑ ↓ で動くと、1 通の選び方に戻る。
    @Test func movingWithTheKeyboardEndsTheMultipleSelection() async {
        let (model, _) = await loaded()
        model.selectAll()
        await model.selectNext()
        #expect(!model.isMultiSelecting)
        #expect(model.selectedIDs == ids(2))
    }
}
