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
            onDraftsChanged: { changes += 1 }
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
