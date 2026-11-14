import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 受信トレイをすべて既読にする窓口の偽物。未読数はアカウントごとに決めた数を返し、既読にすると 0 にする。
private final class MarkReadSpyRepository: MailRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var unread: [AccountID: Int]
    private var log: [AccountID?] = []
    private let failure: (any Error)?

    init(unread: [AccountID: Int], failure: (any Error)? = nil) {
        self.unread = unread
        self.failure = failure
    }

    var requests: [AccountID?] { lock.withLock { log } }

    func accounts() async throws -> [Account] {
        [
            Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A"),
            Account(id: AccountID("b"), provider: .gmail, emailAddress: "b@gmail.com", displayName: "B"),
        ]
    }

    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] { [] }

    func unreadCount(in selection: MailboxSelection) async throws -> Int {
        guard selection.role == .inbox || selection.role == .unread else { return 0 }
        return lock.withLock {
            selection.accountID.map { unread[$0] ?? 0 } ?? unread.values.reduce(0, +)
        }
    }

    func body(for id: MessageID) async throws -> MessageBody { MessageBody(messageID: id, to: [], text: "") }

    func attachmentData(for id: MessageID, index: Int) async throws -> Data { Data() }

    func perform(_ action: MessageAction, on id: MessageID) async throws {}

    func markInboxRead(account: AccountID?) async throws -> Int {
        lock.withLock { log.append(account) }
        if let failure { throw failure }
        return lock.withLock {
            var total = 0
            for id in unread.keys where account == nil || id == account {
                total += unread[id] ?? 0
                unread[id] = 0
            }
            return total
        }
    }
}

/// 受信トレイをすべて既読にする (2026-11-15 オーナーの依頼)。確かめてから、サーバーの古い未読も含めて既読にする。
@MainActor @Suite struct InboxModelMarkInboxReadTests {
    private let a = AccountID("a")
    private let b = AccountID("b")

    private func loaded(_ repository: MarkReadSpyRepository) async -> InboxModel {
        let model = InboxModel(repository: repository)
        await model.load()
        return model
    }

    /// 統合受信トレイでは、すべてのアカウント。確かめてから既読にし、未読数を読み直す。
    @Test func unifiedInboxMarksEveryAccountAfterConfirming() async {
        let repository = MarkReadSpyRepository(unread: [a: 401, b: 3])
        let model = await loaded(repository)
        #expect(model.canMarkInboxRead)

        model.askToMarkInboxRead()
        let request = model.markInboxReadRequest
        #expect(request == InboxModel.MarkInboxReadRequest(accountID: nil, scope: "すべてのアカウント", unreadCount: 404))
        #expect(repository.requests.isEmpty)  // 確かめるまでは何もしない

        await model.markInboxRead(account: nil)
        #expect(repository.requests == [nil])
        #expect(model.unifiedUnreadCount == 0)
        #expect(model.folders.first { $0.role == .inbox }?.badge == 0)
        #expect(model.markInboxReadRequest == nil)
        #expect(model.actionError == nil)
    }

    /// アカウントを選んでいるときは、そのアカウントだけ。
    @Test func aChosenAccountMarksOnlyThatAccount() async {
        let repository = MarkReadSpyRepository(unread: [a: 401, b: 3])
        let model = await loaded(repository)
        await model.select(.account(b, .unread))
        model.askToMarkInboxRead()
        #expect(model.markInboxReadRequest == InboxModel.MarkInboxReadRequest(accountID: b, scope: "B", unreadCount: 3))

        await model.markInboxRead(account: b)
        #expect(repository.requests == [b])
        #expect(model.unifiedUnreadCount == 401)
    }

    /// サイドバーで右クリックしたアカウントを、直接指定できる。
    @Test func aRightClickedAccountCanBeNamed() async {
        let model = await loaded(MarkReadSpyRepository(unread: [a: 401, b: 3]))
        model.askToMarkInboxRead(account: a)
        #expect(model.markInboxReadRequest?.accountID == a)
        #expect(model.markInboxReadRequest?.unreadCount == 401)
        model.cancelMarkInboxRead()
        #expect(model.markInboxReadRequest == nil)
    }

    /// 未読がない・見本のメールのときは、出さない。
    @Test func notWhenNothingIsUnreadOrWithSamples() async {
        let empty = await loaded(MarkReadSpyRepository(unread: [a: 0, b: 0]))
        #expect(!empty.canMarkInboxRead)
        empty.askToMarkInboxRead()
        #expect(empty.markInboxReadRequest == nil)

        let samples = InboxModel(repository: MarkReadSpyRepository(unread: [a: 5]), isShowingSamples: true)
        await samples.load()
        #expect(!samples.canMarkInboxRead)
        samples.askToMarkInboxRead()
        #expect(samples.markInboxReadRequest == nil)
    }

    /// できなかったら知らせる。
    @Test func failuresAreShown() async {
        let model = await loaded(MarkReadSpyRepository(unread: [a: 4], failure: MailRepositoryError.actionUnavailable))
        await model.markInboxRead(account: nil)
        #expect(model.actionError != nil)
    }
}
