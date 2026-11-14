import AccountKit
import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 送ったものを覚える偽の送信用の接続。本物のサーバーには触れない。
private actor SpySender: MailSendingSession {
    private(set) var count = 0
    private let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        count += 1
    }
    func close() async {}
}

/// 送信の取り消し (T24、US-15)。
@MainActor @Suite struct MailServiceUndoSendTests {
    private struct SavedAccount: Encodable {
        var account: Account
        var imap: ServerSettings
        var smtp: ServerSettings
    }

    private func service(
        delay: Duration, sender: SpySender = SpySender(), sendingFails: Bool = false, withAccount: Bool = true,
        provider: MailProvider = .gmail
    ) async throws -> MailService {
        let account = Account(id: AccountID("a"), provider: provider, emailAddress: "a@example.com", displayName: "A")
        let storage = InMemoryAccountListStorage()
        if withAccount {
            try storage.save(JSONEncoder().encode([SavedAccount(
                account: account,
                imap: ServerSettings(host: "imap.example.com", port: 993),
                smtp: ServerSettings(host: "smtp.example.com", port: 465)
            )]))
        }
        let secrets = InMemorySecretStore()
        try secrets.set(Data("pw".utf8), for: "password.a")
        let directory = AccountDirectory(
            storage: storage, secrets: secrets,
            connector: { _, _ in throw CancellationError() },
            senderConnector: { _, _ in
                if sendingFails { throw CancellationError() }
                return sender
            }
        )
        let service = MailService(directory: directory, store: InMemoryMessageStore(), undoSendDelay: { delay })
        await service.start()
        return service
    }

    private func draft(_ subject: String = "会議") -> Draft {
        Draft(accountID: AccountID("a"), to: [Contact(name: "", address: "t@example.com")], subject: subject, body: "本文")
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<300 where !(await condition()) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func cancellingGivesTheDraftBackAndSendsNothing() async throws {
        let sender = SpySender()
        let service = try await service(delay: .milliseconds(300), sender: sender)
        #expect(await service.sendLater(draft()))
        let pending = try #require(service.pendingSends.first)
        #expect(pending.subject == "会議")

        #expect(await service.cancelSend(pending.id))
        #expect(service.pendingSends.isEmpty)
        #expect(service.takeRestoredDraft(pending.id)?.subject == "会議")
        #expect(service.takeRestoredDraft(pending.id) == nil)  // 1 回だけ受け取れる

        try await Task.sleep(for: .milliseconds(500))
        #expect(await sender.count == 0)
    }

    @Test func itIsSentAfterTheDelay() async throws {
        let sender = SpySender()
        let service = try await service(delay: .milliseconds(30), sender: sender)
        #expect(await service.sendLater(draft()))
        await waitUntil { await sender.count == 1 }
        #expect(await sender.count == 1)
        await waitUntil { service.pendingSends.isEmpty }
        #expect(service.pendingSends.isEmpty)
        #expect(service.sendNotices.isEmpty)
    }

    /// 送り始めたら、もう取り消せないので「送信を取り消す」は消す。終えるときは、送り終わるまで待つ。
    @Test func onceSendingStartsItCanNoLongerBeUndone() async throws {
        let sender = SpySender(delay: .milliseconds(300))
        let service = try await service(delay: .milliseconds(20), sender: sender)
        #expect(await service.sendLater(draft()))
        let id = try #require(service.pendingSends.first?.id)
        await waitUntil { service.pendingSends.isEmpty }
        #expect(service.pendingSends.isEmpty)
        #expect(service.hasPendingSends)  // 送っている途中
        #expect(await service.cancelSend(id) == false)
        #expect(await service.flushSends())
        #expect(await sender.count == 1)
        #expect(!service.hasPendingSends)
    }

    /// 0 秒 (すぐ送る) のときは預からない。作成ウィンドウがその場で送る。
    @Test func zeroSecondsIsNotQueued() async throws {
        let service = try await service(delay: .zero)
        #expect(await service.sendLater(draft()) == false)
        #expect(service.pendingSends.isEmpty)
    }

    /// 見本のメールのときも預からない (送れないことを作成ウィンドウで知らせるため)。
    @Test func samplesAreNotQueued() async throws {
        let service = try await service(delay: .seconds(10), withAccount: false)
        #expect(await service.sendLater(draft()) == false)
    }

    /// 送れなかったら知らせて、書いたものを作成ウィンドウで開き直せる。
    @Test func aFailedSendCanBeReopened() async throws {
        let service = try await service(delay: .milliseconds(20), sendingFails: true)
        #expect(await service.sendLater(draft()))
        await waitUntil { !service.sendNotices.isEmpty }
        let notice = try #require(service.sendNotices.first)
        #expect(notice.subject == "会議")
        #expect(notice.canReopen)
        #expect(service.takeRestoredDraft(notice.id)?.subject == "会議")
        service.dismissSendNotice(notice.id)
        #expect(service.sendNotices.isEmpty)
    }

    /// アプリを終えるときに送れなかったら、終えずに知らせる (書いたものを失わないため)。
    @Test func aFailedFlushIsReported() async throws {
        let service = try await service(delay: .seconds(30), sendingFails: true)
        #expect(await service.sendLater(draft()))
        #expect(await service.flushSends() == false)
        #expect(service.sendNotices.first?.canReopen == true)
        // メインウィンドウが閉じていても見えるよう、開いてもらう
        #expect(service.openRequest.serial == 1)
    }

    /// アプリを終えるときは、待たずに送ってから終わる。
    @Test func flushSendsRightAway() async throws {
        let sender = SpySender()
        let service = try await service(delay: .seconds(30), sender: sender)
        #expect(await service.sendLater(draft()))
        #expect(service.hasPendingSends)
        #expect(await service.flushSends())
        #expect(await sender.count == 1)
        #expect(!service.hasPendingSends)
    }

    /// 送れたが「送信済み」に残せなかったことも知らせる (取り消しを入れる前と同じ)。開き直しはしない。
    @Test func sentButNotSavedIsReported() async throws {
        let service = try await service(delay: .milliseconds(20), provider: .icloud)
        #expect(await service.sendLater(draft()))
        await waitUntil { !service.sendNotices.isEmpty }
        let notice = try #require(service.sendNotices.first)
        #expect(!notice.canReopen)
        #expect(service.takeRestoredDraft(notice.id) == nil)
    }
}

/// 取り消しの秒数の設定 (T24)。
@Suite struct UndoSendSettingTests {
    @Test func defaultsToTenSeconds() {
        let defaults = UserDefaults(suiteName: "UndoSendSettingTests.\(UUID())")!
        #expect(UndoSendSetting.delay(in: defaults) == .seconds(10))
        defaults.set(0, forKey: UndoSendSetting.key)
        #expect(UndoSendSetting.delay(in: defaults) == .zero)
        defaults.set(30, forKey: UndoSendSetting.key)
        #expect(UndoSendSetting.delay(in: defaults) == .seconds(30))
    }

    /// 決めた選択肢にない値 (手で書き換えたなど) は、近い範囲に収める。
    @Test func outOfRangeValuesAreClamped() {
        let defaults = UserDefaults(suiteName: "UndoSendSettingTests.\(UUID())")!
        defaults.set(999, forKey: UndoSendSetting.key)
        #expect(UndoSendSetting.delay(in: defaults) == .seconds(30))
        defaults.set(-5, forKey: UndoSendSetting.key)
        #expect(UndoSendSetting.delay(in: defaults) == .zero)
    }
}

/// 作成ウィンドウ側 (T24)。
@MainActor @Suite struct ComposeModelUndoSendTests {
    @Test func whenQueuedTheWindowFinishesWithoutSendingItself() async throws {
        let repository = PreviewMailRepository()
        var queued: [Draft] = []
        let model = ComposeModel(repository: repository, sendLater: { queued.append($0); return true })
        await model.load(.new())
        model.to = "t@example.com"
        model.subject = "会議"
        await model.send()
        #expect(model.outcome == .sent)
        #expect(queued.map(\.subject) == ["会議"])
        #expect(model.errorMessage == nil)
    }

    /// 取り消したメールを、元の中身のまま開き直す。署名を二重に入れない。
    @Test func aRestoredDraftFillsTheFields() async throws {
        let repository = PreviewMailRepository()
        let account = try #require(try await repository.accounts().first)
        let signatures = SignatureStore(storage: InMemoryAccountListStorage())
        try await signatures.setSignature("山田", for: account.id)
        let restored = Draft(
            accountID: account.id,
            to: [Contact(name: "田中", address: "t@example.com")],
            cc: [Contact(name: "", address: "c@example.com")],
            subject: "会議",
            body: "本文\n\n-- \n山田",
            attachments: [DraftAttachment(filename: "a.txt", mimeType: "text/plain", data: Data("x".utf8))],
            inReplyTo: "abc@example.com",
            references: ["abc@example.com"]
        )
        let model = ComposeModel(repository: repository, signatures: signatures)
        await model.load(.restoring(UUID()), restored: restored)

        #expect(model.accountID == account.id)
        #expect(model.to == "田中 <t@example.com>")
        #expect(model.cc == "c@example.com")
        #expect(model.showsCcAndBcc)
        #expect(model.subject == "会議")
        #expect(model.body == "本文\n\n-- \n山田")
        #expect(model.attachments.map(\.filename) == ["a.txt"])
        let again = try model.makeDraft()
        #expect(again.inReplyTo == "abc@example.com")
        #expect(again.references == ["abc@example.com"])
    }
}
