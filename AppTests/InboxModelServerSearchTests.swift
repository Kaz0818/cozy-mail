import Foundation
import MailStore
import Testing
@testable import CozyMail

/// サーバー側の検索だけを決めた形で返す窓口。Mac 内の検索は m1・m2、サーバーは m2 (重なり)・古いメール 2 通。
private final class ServerSearchSpyRepository: MailRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private let failure: (any Error)?
    private let base = Date(timeIntervalSince1970: 1_794_000_000)

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var calls: [String] { lock.withLock { log } }

    private func record(_ entry: String) { lock.withLock { log.append(entry) } }

    private func summary(_ id: String, days: Double, isRead: Bool = false, isStarred: Bool = false) -> MessageSummary {
        MessageSummary(
            id: MessageID(id), accountID: AccountID("a"), mailbox: .inbox,
            sender: Contact(name: "差出人", address: "s@example.com"), subject: "件名 \(id)", preview: "",
            date: base.addingTimeInterval(-days * 86400), isRead: isRead, isStarred: isStarred
        )
    }

    func accounts() async throws -> [Account] {
        [Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")]
    }

    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] { [] }

    func unreadCount(in selection: MailboxSelection) async throws -> Int { 0 }

    func search(_ text: String, filter: MessageFilter) async throws -> [MessageSummary] {
        record("search \(text)")
        return [summary("m1", days: 1), summary("m2", days: 2, isRead: true)]
    }

    func searchServer(_ text: String) async throws -> [MessageSummary] {
        record("server \(text)")
        if let failure { throw failure }
        return [
            summary("m2", days: 2, isRead: true),
            summary("server/old1", days: 300, isStarred: true),
            summary("server/old2", days: 400, isRead: true),
        ]
    }

    func body(for id: MessageID) async throws -> MessageBody {
        record("body \(id.rawValue)")
        return MessageBody(messageID: id, to: [], text: "本文")
    }

    func attachmentData(for id: MessageID, index: Int) async throws -> Data { Data() }

    func perform(_ action: MessageAction, on id: MessageID) async throws {
        record("perform \(action) \(id.rawValue)")
    }
}

/// サーバー側の検索 (T27、US-10)。Mac 内の検索の結果の下に「サーバーで探す」を出し、見つけたメールを足す。
@MainActor @Suite struct InboxModelServerSearchTests {
    private func searching(_ repository: ServerSearchSpyRepository = ServerSearchSpyRepository()) async -> InboxModel {
        let model = InboxModel(repository: repository)
        await model.load()
        await model.search("請求書")
        return model
    }

    private func ids(_ model: InboxModel) -> [String] {
        model.messages.map(\.id.rawValue)
    }

    /// 押すとサーバーで探し、Mac 内の結果の下に、重ならないメールだけを足す。
    @Test func addsServerResultsBelowTheLocalOnes() async {
        let repository = ServerSearchSpyRepository()
        let model = await searching(repository)
        #expect(model.serverSearchState == .idle)
        #expect(model.canSearchOnServer)

        await model.searchOnServer()
        #expect(repository.calls.contains("server 請求書"))
        #expect(ids(model) == ["m1", "m2", "server/old1", "server/old2"])
        #expect(model.serverSearchState == .finished(added: 2))
        #expect(!model.canSearchOnServer)  // 同じ言葉では、もう一度は出さない
        #expect(model.subtitle == "「請求書」・4件")
    }

    /// 言葉を変えたら、サーバーの結果は消え、もう一度探せる。
    @Test func changingTheTextClearsTheServerResults() async {
        let model = await searching()
        await model.searchOnServer()
        await model.search("請求")
        #expect(ids(model) == ["m1", "m2"])
        #expect(model.serverSearchState == .idle)
        #expect(model.canSearchOnServer)
    }

    /// 検索していないときは、サーバーで探せない。フォルダを選び直すと消える。
    @Test func onlyWhileSearching() async {
        let repository = ServerSearchSpyRepository()
        let model = InboxModel(repository: repository)
        await model.load()
        #expect(!model.canSearchOnServer)
        await model.searchOnServer()
        #expect(!repository.calls.contains { $0.hasPrefix("server") })

        await model.search("請求書")
        await model.searchOnServer()
        await model.select(.unified(.archive))
        #expect(model.serverSearchState == .idle)
        #expect(!model.messages.contains { ServerMessage.isServerOnly($0.id) })
    }

    /// 「未読」「スター付き」で絞っているときは、サーバーの結果も絞る。
    @Test func theFilterAppliesToServerResults() async {
        let model = await searching()
        await model.setFilter(.starred)
        await model.searchOnServer()
        #expect(ids(model).filter { $0.hasPrefix("server/") } == ["server/old1"])
    }

    /// サーバーで見つけた (保存していない) メールは開けるが、整理の操作はできない。開いても既読にしにいかない。
    @Test func serverOnlyMessagesAreReadOnly() async throws {
        let repository = ServerSearchSpyRepository()
        let model = await searching(repository)
        await model.searchOnServer()
        let old = try #require(model.messages.first { $0.id.rawValue == "server/old1" })
        for action in [MessageAction.markRead, .star, .unstar, .archive, .moveToTrash, .markAsJunk] {
            #expect(!model.canPerform(action, on: old))
        }
        await model.selectMessage(old.id)
        #expect(model.selectedBody?.text == "本文")
        #expect(!repository.calls.contains { $0.hasPrefix("perform") })
        #expect(model.actionError == nil)
    }

    /// つながらなかったら、知らせて、また押せるようにする。Mac 内の結果はそのまま。
    @Test func failuresAreShownAndCanBeRetried() async {
        let model = await searching(ServerSearchSpyRepository(failure: MailRepositoryError.actionUnavailable))
        await model.searchOnServer()
        guard case .failed = model.serverSearchState else {
            Issue.record("失敗の知らせがない: \(model.serverSearchState)")
            return
        }
        #expect(ids(model) == ["m1", "m2"])
        #expect(model.canSearchOnServer)
    }

    /// 見本のメールを出しているときは、サーバーで探せない。
    @Test func notWithSamples() async {
        let repository = ServerSearchSpyRepository()
        let model = InboxModel(repository: repository, isShowingSamples: true)
        await model.load()
        await model.search("請求書")
        #expect(!model.canSearchOnServer)
        await model.searchOnServer()
        #expect(!repository.calls.contains { $0.hasPrefix("server") })
    }
}
