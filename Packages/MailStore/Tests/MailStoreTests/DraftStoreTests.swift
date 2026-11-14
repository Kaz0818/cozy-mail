import Foundation
import Testing
@testable import MailStore

/// 下書きを Mac に保存する (T23a、US-14)。一時フォルダで試す。
@Suite struct DraftStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DraftStoreTests-\(UUID().uuidString)")
    }

    private func content(_ subject: String, to: String = "田中 <t@example.com>, 打ちかけ") -> DraftContent {
        DraftContent(
            accountID: AccountID("a"), to: to, subject: subject, body: "本文",
            attachments: [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("中身".utf8))],
            inReplyTo: "abc@example.com", references: ["abc@example.com"], quote: "> 引用"
        )
    }

    @Test func savesAndReadsBackEverything() async throws {
        let store = DraftStore(directory: temporaryDirectory())
        let id = UUID()
        let saved = content("会議")
        try await store.save(saved, id: id, at: Date(timeIntervalSince1970: 100))

        // 別に作った保存先からも読める (アプリを開き直したのと同じ)
        let reopened = DraftStore(directory: await store.directory)
        let loaded = try #require(await reopened.draft(id))
        #expect(loaded.content == saved)  // 読めない宛先 (打ちかけ) もそのまま残る
        #expect(loaded.savedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func listsNewestFirstAndOverwritesTheSameDraft() async throws {
        let store = DraftStore(directory: temporaryDirectory())
        let first = UUID()
        let second = UUID()
        try await store.save(content("1"), id: first, at: Date(timeIntervalSince1970: 100))
        try await store.save(content("2"), id: second, at: Date(timeIntervalSince1970: 200))
        try await store.save(content("1 (直した)"), id: first, at: Date(timeIntervalSince1970: 300))

        let all = await store.all()
        #expect(all.map(\.content.subject) == ["1 (直した)", "2"])
    }

    @Test func deleteRemovesTheDraft() async throws {
        let store = DraftStore(directory: temporaryDirectory())
        let id = UUID()
        try await store.save(content("会議"), id: id)
        try await store.delete(id)
        #expect(await store.draft(id) == nil)
        #expect(await store.all().isEmpty)
        try await store.delete(id)  // ないものを消しても失敗しない
    }

    /// 壊れたファイルがあっても、ほかの下書きは読める。
    @Test func brokenFilesAreSkipped() async throws {
        let directory = temporaryDirectory()
        let store = DraftStore(directory: directory)
        try await store.save(content("会議"), id: UUID())
        try Data("こわれた".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(await store.all().map(\.content.subject) == ["会議"])
    }

    /// サーバーの写しを消せなかったものを覚えておく (T23b)。下書きの一覧には出ない。
    @Test func pendingServerRemovalsAreKeptApartFromDrafts() async throws {
        let store = DraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("Drafts-\(UUID().uuidString)"))
        let first = UUID()
        let second = UUID()
        try await store.addPendingRemoval(first, accountID: AccountID("a"))
        try await store.addPendingRemoval(first, accountID: AccountID("a"))  // 同じものは 1 つだけ
        try await store.addPendingRemoval(second, accountID: AccountID("b"))
        #expect(await store.all().isEmpty)
        #expect(await store.pendingRemovals() == [
            PendingServerRemoval(id: first, accountID: AccountID("a")),
            PendingServerRemoval(id: second, accountID: AccountID("b")),
        ])

        try await store.updatePendingRemovals([PendingServerRemoval(id: second, accountID: AccountID("b"), attempts: 1)])
        #expect(await store.pendingRemovals() == [PendingServerRemoval(id: second, accountID: AccountID("b"), attempts: 1)])
        try await store.updatePendingRemovals([])
        #expect(await store.pendingRemovals().isEmpty)
    }

    @Test func contentBecomesADraftForSending() {
        let draft = content("会議").draft
        #expect(draft.to == [Contact(name: "田中", address: "t@example.com")])  // 読めない宛先は除く
        #expect(draft.subject == "会議")
        #expect(draft.quote == "> 引用")
        #expect(draft.attachments.map(\.filename) == ["a.txt"])
    }
}

/// 下書きフォルダに、Mac に保存した下書きも出す (T23a)。
@Suite struct DraftsMergingRepositoryTests {
    private let account = AccountID("a")

    private func setUp() async throws -> (DraftsMergingRepository, DraftStore, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DraftsMerging-\(UUID().uuidString)")
        let drafts = DraftStore(directory: directory)
        let id = UUID()
        try await drafts.save(
            DraftContent(accountID: account, to: "田中 <t@example.com>", subject: "書きかけ", body: "こんにちは。続きはあとで"),
            id: id, at: Date(timeIntervalSince1970: 1_794_000_000)
        )
        let repository = DraftsMergingRepository(base: PreviewMailRepository(), drafts: drafts)
        return (repository, drafts, id)
    }

    @Test func localDraftsAppearInTheDraftsFolder() async throws {
        let (repository, _, id) = try await setUp()
        let unified = try await repository.messages(in: .unified(.drafts), filter: .all)
        let local = try #require(unified.first { $0.id == LocalDraft.messageID(id) })
        #expect(local.subject == "書きかけ")
        #expect(local.mailbox == .drafts)
        #expect(local.isRead)
        #expect(local.recipients == [Contact(name: "田中", address: "t@example.com")])
        #expect(local.preview.hasPrefix("こんにちは"))
        // 見本の下書きもそのまま出る
        #expect(unified.count > 1)

        #expect(try await repository.messages(in: .account(account, .drafts), filter: .all).contains { $0.id == local.id })
        #expect(try await !repository.messages(in: .account(AccountID("other"), .drafts), filter: .all).contains { $0.id == local.id })
        #expect(try await !repository.messages(in: .unified(.inbox), filter: .all).contains { $0.id == local.id })
        #expect(try await repository.messages(in: .unified(.drafts), filter: .unread).allSatisfy { $0.id != local.id })
    }

    @Test func theBodyOfALocalDraftIsItsText() async throws {
        let (repository, _, id) = try await setUp()
        let body = try await repository.body(for: LocalDraft.messageID(id))
        #expect(body.text == "こんにちは。続きはあとで")
        #expect(body.to == [Contact(name: "田中", address: "t@example.com")])
    }

    /// 下書きを「削除」すると、Mac の下書きを消す。ほかの操作はできない。
    @Test func trashingALocalDraftDeletesIt() async throws {
        let (repository, drafts, id) = try await setUp()
        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.archive, on: LocalDraft.messageID(id))
        }
        try await repository.perform(.moveToTrash, on: [LocalDraft.messageID(id)])
        #expect(await drafts.draft(id) == nil)
    }

    /// Mac の下書きを消したら、消した下書きを知らせる (サーバーの写しを消すため、T23b)。消せない操作では知らせない。
    @Test func deletingALocalDraftReportsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DraftsMerging-\(UUID().uuidString)")
        let drafts = DraftStore(directory: directory)
        let id = UUID()
        try await drafts.save(DraftContent(accountID: account, subject: "書きかけ"), id: id)
        let deleted = DeletedDrafts()
        let repository = DraftsMergingRepository(
            base: PreviewMailRepository(), drafts: drafts, onDelete: { await deleted.add($0) }
        )
        await #expect(throws: MailRepositoryError.actionNotApplicable) {
            try await repository.perform(.archive, on: LocalDraft.messageID(id))
        }
        #expect(await deleted.list.isEmpty)
        try await repository.perform(.moveToTrash, on: LocalDraft.messageID(id))
        let reported = await deleted.list
        #expect(reported.map(\.id) == [id])
        #expect(reported.first?.content.accountID == account)
    }

    private actor DeletedDrafts {
        private(set) var list: [SavedDraft] = []
        func add(_ saved: SavedDraft) { list.append(saved) }
    }

    @Test func localDraftIDsRoundTrip() {
        let id = UUID()
        #expect(LocalDraft.id(from: LocalDraft.messageID(id)) == id)
        #expect(LocalDraft.id(from: MessageID("a/1")) == nil)
    }
}
