import AccountKit
import Foundation
import MailStore
import Testing
@testable import CozyMail

/// 送ったものを覚える窓口。返信の元は見本のメールから作る。
private final class SendSpyRepository: MailRepository, @unchecked Sendable {
    private let base = PreviewMailRepository()
    private let lock = NSLock()
    private var storage: [Draft] = []
    private let outcome: SendOutcome

    init(outcome: SendOutcome = .sent) {
        self.outcome = outcome
    }

    var sent: [Draft] { lock.withLock { storage } }

    func accounts() async throws -> [Account] { try await base.accounts() }
    func messages(in selection: MailboxSelection, filter: MessageFilter) async throws -> [MessageSummary] {
        try await base.messages(in: selection, filter: filter)
    }
    func unreadCount(in selection: MailboxSelection) async throws -> Int { try await base.unreadCount(in: selection) }
    func body(for id: MessageID) async throws -> MessageBody { try await base.body(for: id) }
    func attachmentData(for id: MessageID, index: Int) async throws -> Data { Data() }
    func perform(_ action: MessageAction, on id: MessageID) async throws {}
    func replySource(for id: MessageID) async throws -> ReplySource { try await base.replySource(for: id) }
    func send(_ draft: Draft) async throws -> SendOutcome {
        lock.withLock { storage.append(draft) }
        return outcome
    }
}

@MainActor @Suite struct ComposeModelTests {
    private func firstSample() async throws -> MessageSummary {
        try #require(try await PreviewMailRepository().messages(in: .unified(.inbox), filter: .all).first)
    }

    @Test func newMessageStartsEmptyFromTheFirstAccount() async throws {
        let repository = SendSpyRepository()
        let model = ComposeModel(repository: repository)
        await model.load(.new())
        #expect(model.accountID == (try await repository.accounts()).first?.id)
        #expect(model.to.isEmpty && model.subject.isEmpty && model.body.isEmpty)
        #expect(model.windowTitle == "新規メッセージ")
    }

    @Test func replyIsPrefilledFromTheReceivingAccount() async throws {
        let sample = try await firstSample()
        let model = ComposeModel(repository: SendSpyRepository())
        await model.load(.replying(.reply, to: sample.id))

        #expect(model.accountID == sample.accountID)
        #expect(model.to == "\(sample.sender.name) <\(sample.sender.address)>")
        #expect(model.subject == "Re: \(sample.subject)")
        #expect(model.body.contains("> "))
        #expect(model.windowTitle == "Re: \(sample.subject)")
    }

    @Test func sendingParsesTheRecipientFields() async throws {
        let repository = SendSpyRepository()
        let model = ComposeModel(repository: repository)
        await model.load(.new())
        model.to = "田中 <k.tanaka@example.com>, sato@example.org"
        model.bcc = "boss@example.com"
        model.subject = "件名"
        model.body = "本文"

        await model.send()

        #expect(model.errorMessage == nil)
        #expect(model.outcome == .sent)
        let draft = try #require(repository.sent.first)
        #expect(draft.to == [Contact(name: "田中", address: "k.tanaka@example.com"), Contact(name: "", address: "sato@example.org")])
        #expect(draft.bcc == [Contact(name: "", address: "boss@example.com")])
        #expect(draft.subject == "件名")
    }

    @Test func unreadableAddressIsShownAndNothingIsSent() async {
        let repository = SendSpyRepository()
        let model = ComposeModel(repository: repository)
        await model.load(.new())
        model.to = "k.tanaka@example.com, tanaka-san"

        await model.send()

        #expect(model.errorMessage == "「tanaka-san」はメールアドレスとして読めません。")
        #expect(repository.sent.isEmpty)
        #expect(model.outcome == nil)
    }

    @Test func missingRecipientIsShown() async {
        let model = ComposeModel(repository: SendSpyRepository())
        await model.load(.new())
        await model.send()
        #expect(model.errorMessage == "宛先を入れてください。")
    }

    /// 見本のメールのときは送れないことを、分かる言葉で知らせる。
    @Test func samplesExplainThatAnAccountIsNeeded() async {
        let model = ComposeModel(repository: PreviewMailRepository())
        await model.load(.new())
        model.to = "k.tanaka@example.com"
        await model.send()
        #expect(model.errorMessage?.contains("アカウントを追加") == true)
        #expect(model.outcome == nil)
    }

    @Test func sentButNotSavedIsKept() async {
        let model = ComposeModel(repository: SendSpyRepository(outcome: .sentButNotSaved("no Sent")))
        await model.load(.new())
        model.to = "k.tanaka@example.com"
        await model.send()
        #expect(model.outcome == .sentButNotSaved("no Sent"))
        #expect(!model.canSend)
    }

    @Test func attachmentsCanBeAddedAndRemoved() async throws {
        let model = ComposeModel(repository: SendSpyRepository())
        await model.load(.new())
        model.addAttachment(filename: "a.pdf", mimeType: "application/pdf", data: Data([1]))
        model.addAttachment(filename: "b.txt", mimeType: "text/plain", data: Data([2]))
        let first = try #require(model.attachments.first)
        model.removeAttachment(first.id)
        #expect(model.attachments.map(\.filename) == ["b.txt"])
    }
}

/// 署名 (T25)。差出人のアカウントの署名が入り、差出人を変えると入れ替わる。
@MainActor @Suite struct ComposeModelSignatureTests {
    private func signatures(_ pairs: [(AccountID, String)]) async throws -> SignatureStore {
        let store = SignatureStore(storage: InMemoryAccountListStorage())
        for (id, text) in pairs { try await store.setSignature(text, for: id) }
        return store
    }

    @Test func aNewMessageGetsTheSenderSignature() async throws {
        let repository = PreviewMailRepository()
        let accounts = try await repository.accounts()
        let model = ComposeModel(repository: repository, signatures: try await signatures([(accounts[0].id, "山田 (仕事)")]))
        await model.load(.new())
        #expect(model.body == "\n\n-- \n山田 (仕事)")
    }

    @Test func switchingTheSenderSwapsTheSignature() async throws {
        let repository = PreviewMailRepository()
        let accounts = try await repository.accounts()
        let model = ComposeModel(repository: repository, signatures: try await signatures([
            (accounts[0].id, "山田 (仕事)"), (accounts[1].id, "やまだ"),
        ]))
        await model.load(.new())
        model.body = "こんにちは" + model.body
        model.accountID = accounts[1].id
        #expect(model.body == "こんにちは\n\n-- \nやまだ")
        model.accountID = accounts[2].id
        #expect(model.body == "こんにちは")
    }

    @Test func aReplyPutsTheSignatureAboveTheQuote() async throws {
        let repository = PreviewMailRepository()
        let first = try #require(try await repository.messages(in: .unified(.inbox), filter: .all).first)
        let model = ComposeModel(repository: repository, signatures: try await signatures([(first.accountID, "山田")]))
        await model.load(.replying(.reply, to: first.id))
        #expect(model.body.hasPrefix("\n\n-- \n山田\n\n"))
        #expect(model.body.contains("\n> "))
    }

    @Test func withoutSignaturesNothingChanges() async throws {
        let model = ComposeModel(repository: PreviewMailRepository())
        await model.load(.new())
        #expect(model.body.isEmpty)
    }
}

/// 設定の署名の欄 (T25)。アカウントを消したら、その署名も消える。
@MainActor @Suite struct MailServiceSignatureTests {
    @Test func removingAnAccountForgetsItsSignature() async throws {
        let directory = AccountDirectory(
            storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore(),
            connector: { _, _ in throw CancellationError() }, senderConnector: { _, _ in throw CancellationError() }
        )
        let signatures = SignatureStore(storage: InMemoryAccountListStorage())
        let service = MailService(directory: directory, store: InMemoryMessageStore(), signatures: signatures)
        try await service.setSignature("山田", for: AccountID("a"))
        #expect(await signatures.signature(for: AccountID("a")) == "山田")
        await service.removeAccount(AccountID("a"))
        #expect(await signatures.signature(for: AccountID("a")) == "")
    }
}
