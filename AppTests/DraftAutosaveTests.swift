import AccountKit
import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 作成ウィンドウの下書きの自動保存 (T23a、US-14)。保存先は一時フォルダ。
@MainActor @Suite struct DraftAutosaveTests {
    private func drafts() -> DraftStore {
        DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DraftAutosave-\(UUID().uuidString)"))
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 打つのをやめて決めた時間がたったら保存する。
    @Test func editingSavesAfterAPause() async throws {
        let store = drafts()
        var changes = 0
        let model = ComposeModel(
            repository: PreviewMailRepository(), drafts: store, autosaveDelay: .milliseconds(20),
            onDraftsChanged: { change in
                if case .saved = change { changes += 1 }
            }
        )
        await model.load(.new())
        model.subject = "会議"
        model.to = "田中 <t@example.com>, 打ちかけ"
        model.contentChanged()

        await waitUntil { await !store.all().isEmpty }
        let saved = try #require(await store.draft(model.draftID))
        #expect(saved.content.subject == "会議")
        #expect(saved.content.to == "田中 <t@example.com>, 打ちかけ")
        #expect(changes == 1)
    }

    /// 開いただけで何も書いていなければ、閉じても保存しない。
    @Test func untouchedWindowsAreNotSaved() async {
        let store = drafts()
        let model = ComposeModel(repository: PreviewMailRepository(), drafts: store, autosaveDelay: .milliseconds(20))
        await model.load(.new())
        await model.closing()
        #expect(await store.all().isEmpty)
    }

    /// 書きかけで閉じたら、待たずに保存する。
    @Test func closingSavesRightAway() async {
        let store = drafts()
        let model = ComposeModel(repository: PreviewMailRepository(), drafts: store, autosaveDelay: .seconds(60))
        await model.load(.new())
        model.body = "書きかけ"
        model.contentChanged()
        await model.closing()
        #expect(await store.draft(model.draftID)?.content.body == "書きかけ")
    }

    /// 下書きフォルダから開くと、続きが書ける。同じ下書きに上書きする。
    @Test func reopeningADraftContinuesIt() async throws {
        let store = drafts()
        let id = UUID()
        let account = try #require(try await PreviewMailRepository().accounts().first)
        try await store.save(DraftContent(accountID: account.id, to: "t@example.com", cc: "c@example.com", subject: "会議", body: "続き"), id: id)

        let model = ComposeModel(repository: PreviewMailRepository(), drafts: store, autosaveDelay: .milliseconds(20))
        await model.load(.editingDraft(id))
        #expect(model.draftID == id)
        #expect(model.accountID == account.id)
        #expect(model.to == "t@example.com" && model.cc == "c@example.com" && model.showsCcAndBcc)
        #expect(model.subject == "会議" && model.body == "続き")

        model.body = "続きを書いた"
        model.contentChanged()
        await model.closing()
        #expect(await store.all().map(\.content.body) == ["続きを書いた"])
    }

    /// 送ったら (取り消せるよう預けたときも) 下書きは消える。
    @Test func sendingDeletesTheDraft() async {
        let store = drafts()
        let model = ComposeModel(
            repository: PreviewMailRepository(), sendLater: { _ in true }, drafts: store, autosaveDelay: .milliseconds(20)
        )
        await model.load(.new())
        model.to = "t@example.com"
        model.subject = "会議"
        model.contentChanged()
        await model.closing()
        #expect(await store.all().count == 1)

        await model.send()
        #expect(model.outcome == .sent)
        #expect(await store.all().isEmpty)
        await model.closing()
        #expect(await store.all().isEmpty)  // 閉じても、また保存しない
    }

    /// 送ったら「消した」と知らせる。サーバーの写しを消すアカウントは、最後に保存した (= サーバーに置いた) ときの差出人 (T23b)。
    @Test func sendingReportsTheRemovalWithTheSavedAccount() async throws {
        let store = drafts()
        var changes: [DraftChange] = []
        let accounts = try await PreviewMailRepository().accounts()
        try #require(accounts.count >= 2)
        let model = ComposeModel(
            repository: PreviewMailRepository(), sendLater: { _ in true }, drafts: store, autosaveDelay: .seconds(60),
            onDraftsChanged: { changes.append($0) }
        )
        await model.load(.new(), defaultAccount: accounts[0].id)
        model.to = "t@example.com"
        model.contentChanged()
        await model.closing()
        // 保存したあとに差出人を変えて、保存せずに送る
        model.accountID = accounts[1].id
        await model.send()
        #expect(changes == [.saved(model.draftID), .closed(model.draftID), .removed(model.draftID, accounts[0].id)])
    }

    /// サーバーに置くのは、ウィンドウを閉じたときだけ (打つたびに置くと、Gmail の 1 日の上限に届くため)。
    /// 開いただけで何も変えずに閉じたら、置き直さない。
    @Test func closingReportsOnlyWhenSomethingWasSaved() async throws {
        let store = drafts()
        let id = UUID()
        try await store.save(DraftContent(subject: "会議"), id: id)
        var changes: [DraftChange] = []
        let model = ComposeModel(
            repository: PreviewMailRepository(), drafts: store, autosaveDelay: .seconds(60),
            onDraftsChanged: { changes.append($0) }
        )
        await model.load(.editingDraft(id))
        await model.closing()
        #expect(changes.isEmpty)

        model.body = "続き"
        model.contentChanged()
        await model.saveDraft()  // 打っている間の自動保存は、Mac に保存するだけ
        #expect(changes == [.saved(id)])
        await model.closing()
        #expect(changes == [.saved(id), .closed(id)])
    }

    /// 保存していない (サーバーにも置いていない) なら、送っても「消した」とは知らせない。
    @Test func sendingWithoutASavedDraftReportsNothing() async {
        var changes: [DraftChange] = []
        let model = ComposeModel(
            repository: PreviewMailRepository(), sendLater: { _ in true }, drafts: drafts(), autosaveDelay: .seconds(60),
            onDraftsChanged: { changes.append($0) }
        )
        await model.load(.new())
        model.to = "t@example.com"
        await model.send()
        #expect(changes.isEmpty)
    }

    /// 「下書きを捨てる」で消える。そのあと閉じても保存しない。
    @Test func discardingDeletesTheDraft() async {
        let store = drafts()
        let model = ComposeModel(repository: PreviewMailRepository(), drafts: store, autosaveDelay: .milliseconds(20))
        await model.load(.new())
        model.body = "いらない"
        model.contentChanged()
        await model.closing()
        #expect(await store.all().count == 1)

        await model.discardDraft()
        await model.closing()
        #expect(await store.all().isEmpty)
    }
}

/// アカウントがあるとき、下書きフォルダに Mac の下書きも出る (T23a)。
@MainActor @Suite struct MailServiceDraftsTests {
    private struct SavedAccount: Encodable {
        var account: Account
        var imap: ServerSettings
        var smtp: ServerSettings
    }

    @Test func localDraftsAreListedInTheDraftsFolder() async throws {
        let account = Account(id: AccountID("a"), provider: .gmail, emailAddress: "a@gmail.com", displayName: "A")
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode([SavedAccount(
            account: account,
            imap: ServerSettings(host: "imap.example.com", port: 993),
            smtp: ServerSettings(host: "smtp.example.com", port: 465)
        )]))
        let directory = AccountDirectory(
            storage: storage, secrets: InMemorySecretStore(),
            connector: { _, _ in throw CancellationError() }, senderConnector: { _, _ in throw CancellationError() }
        )
        let drafts = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ServiceDrafts-\(UUID().uuidString)"))
        let service = MailService(directory: directory, store: InMemoryMessageStore(), drafts: drafts)
        await service.start()
        let id = UUID()
        try await drafts.save(DraftContent(accountID: account.id, subject: "書きかけ"), id: id)

        let revision = service.revision
        service.draftsChanged()
        #expect(service.revision == revision + 1)
        let listed = try await service.repository.messages(in: .unified(.drafts), filter: .all)
        #expect(listed.map(\.id) == [LocalDraft.messageID(id)])
    }
}

/// 下書きをサーバーにも置く (T23b) ときの、アプリ側の段取り。サーバーには触れず、呼ばれた順番を記録する。
@MainActor @Suite struct ServerDraftCoordinationTests {
    /// 呼ばれたこと (入れる・消す) を、終わった順に記録する。入れるのに時間がかかるようにもできる。
    actor Recorder {
        private(set) var events: [String] = []
        /// 入れ始めた回数 (終わる前に数える)。
        private(set) var uploadsStarted = 0
        private let uploadDelay: Duration
        init(uploadDelay: Duration = .zero) { self.uploadDelay = uploadDelay }
        func upload(_ saved: SavedDraft) async {
            uploadsStarted += 1
            if uploadDelay > .zero { try? await Task.sleep(for: uploadDelay) }
            events.append("upload \(saved.content.subject) to \(saved.content.accountID?.rawValue ?? "-")")
        }
        /// この回数だけ、消すのに失敗する (つながらないとき)。
        private var removalFailures = 0
        func failRemovals(_ count: Int) { removalFailures = count }
        func remove(_ id: UUID, _ account: AccountID) throws {
            if removalFailures > 0 {
                removalFailures -= 1
                events.append("remove from \(account.rawValue) failed")
                throw CancellationError()
            }
            events.append("remove from \(account.rawValue)")
        }
    }

    private struct SavedAccount: Encodable {
        var account: Account
        var imap: ServerSettings
        var smtp: ServerSettings
    }

    private func service(_ recorder: Recorder) async throws -> (MailService, DraftStore) {
        let storage = InMemoryAccountListStorage()
        try storage.save(JSONEncoder().encode(["a", "b"].map { id in
            SavedAccount(
                account: Account(id: AccountID(id), provider: .gmail, emailAddress: "\(id)@gmail.com", displayName: id),
                imap: ServerSettings(host: "imap.example.com", port: 993),
                smtp: ServerSettings(host: "smtp.example.com", port: 465)
            )
        }))
        let directory = AccountDirectory(
            storage: storage, secrets: InMemorySecretStore(),
            connector: { _, _ in throw CancellationError() }, senderConnector: { _, _ in throw CancellationError() }
        )
        let drafts = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Coord-\(UUID().uuidString)"))
        let service = MailService(
            directory: directory, store: InMemoryMessageStore(), drafts: drafts,
            serverDrafts: MailService.ServerDraftHooks(
                upload: { await recorder.upload($0) },
                remove: { try await recorder.remove($0, $1) }
            )
        )
        await service.start()
        return (service, drafts)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func savingUploadsAndRemovingDeletes() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        await service.draftChanged(.closed(id))
        try await drafts.delete(id)
        await service.draftChanged(.removed(id, AccountID("a")))
        #expect(await recorder.events == ["upload 1 to a", "remove from a"])
    }

    /// 入れている途中にまた保存されたら、終わってから最新のものをもう 1 回だけ入れる。
    @Test func savesDuringAnUploadAreCombined() async throws {
        let recorder = Recorder(uploadDelay: .milliseconds(100))
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        let first = Task { await service.draftChanged(.closed(id)) }
        await waitUntil { await recorder.uploadsStarted == 1 }
        for subject in ["2", "3"] {
            try await drafts.save(DraftContent(accountID: AccountID("a"), subject: subject), id: id)
            await service.draftChanged(.closed(id))
        }
        await first.value
        #expect(await recorder.events == ["upload 1 to a", "upload 3 to a"])
    }

    /// 差出人を変えたら、前のアカウントのサーバーの写しを消してから入れる。
    @Test func changingTheAccountRemovesTheOldCopy() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        await service.draftChanged(.closed(id))
        try await drafts.save(DraftContent(accountID: AccountID("b"), subject: "1"), id: id)
        await service.draftChanged(.closed(id))
        try await drafts.delete(id)
        await service.draftChanged(.removed(id, AccountID("b")))
        #expect(await recorder.events == ["upload 1 to a", "remove from a", "upload 1 to b", "remove from b"])
    }

    /// 消すのは、入れている途中のものが終わってから (消したあとに入れてしまわないように)。
    @Test func removingWaitsForAnUploadInProgress() async throws {
        let recorder = Recorder(uploadDelay: .milliseconds(100))
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        let upload = Task { await service.draftChanged(.closed(id)) }
        await waitUntil { await recorder.uploadsStarted == 1 }
        try await drafts.delete(id)
        await service.draftChanged(.removed(id, AccountID("a")))
        await upload.value
        #expect(await recorder.events == ["upload 1 to a", "remove from a"])
    }

    /// 打っている間の自動保存では、サーバーに置かない。
    @Test func autosavingDoesNotUpload() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        let revision = service.revision
        await service.draftChanged(.saved(id))
        #expect(service.revision == revision + 1)
        #expect(await recorder.events.isEmpty)
    }

    /// 消せなかった (つながらなかった) 写しは覚えておき、あとで消し直す。
    @Test func failedRemovalsAreRetriedLater() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        await recorder.failRemovals(1)
        await service.draftChanged(.removed(id, AccountID("a")))
        #expect(await drafts.pendingRemovals() == [PendingServerRemoval(id: id, accountID: AccountID("a"))])

        await service.retryServerDraftRemovals()
        #expect(await recorder.events == ["remove from a failed", "remove from a"])
        #expect(await drafts.pendingRemovals().isEmpty)
    }

    /// 同じ下書きをまた同じアカウントに置いて使っているなら、覚えていた「消す」はやめる (使っている写しを消さない)。
    @Test func aCopyInUseAgainIsNotRemoved() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.addPendingRemoval(id, accountID: AccountID("a"))
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        await service.retryServerDraftRemovals()
        #expect(await recorder.events.isEmpty)
        #expect(await drafts.pendingRemovals().isEmpty)

        // 置き直すときにも、そのアカウントの「消す」は外す
        try await drafts.addPendingRemoval(id, accountID: AccountID("a"))
        await service.draftChanged(.closed(id))
        #expect(await drafts.pendingRemovals().isEmpty)
        #expect(await recorder.events == ["upload 1 to a"])
    }

    /// 何度やっても消せないものは、5 回であきらめる (ずっと試し続けない)。
    @Test func retriesGiveUpAfterFiveAttempts() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        await recorder.failRemovals(100)
        await service.draftChanged(.removed(id, AccountID("a")))
        for _ in 0..<5 {
            #expect(await drafts.pendingRemovals().count == 1)
            await service.retryServerDraftRemovals()
        }
        #expect(await drafts.pendingRemovals().isEmpty)
        #expect(await recorder.events.count == 6)
    }

    /// Mac の下書きを一覧の「削除」で消したときも、サーバーの写しを消す。
    @Test func deletingFromTheListAlsoRemovesTheServerCopy() async throws {
        let recorder = Recorder()
        let (service, drafts) = try await service(recorder)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: AccountID("a"), subject: "1"), id: id)
        try await service.repository.perform(.moveToTrash, on: LocalDraft.messageID(id))
        await waitUntil { await recorder.events.contains("remove from a") }
        #expect(await recorder.events == ["remove from a"])
        #expect(await drafts.draft(id) == nil)
    }
}
