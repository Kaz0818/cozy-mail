import Foundation
import MailCore
import MailStore
import Observation

/// 作成ウィンドウを開く依頼。ウィンドウごとに別のものになるよう、毎回新しい `id` を付ける。
struct ComposeRequest: Codable, Hashable {
    enum Kind: String, Codable {
        case new
        case reply
        case replyAll
        case forward
    }

    var kind: Kind
    /// 返信・転送する元のメール (`MessageID.rawValue`)。
    var messageID: String?
    /// 送信を取り消した・送れなかったメールを開き直すとき、`MailService` が預かっている下書きの番号 (T24)。
    var restoredDraftID: UUID?
    /// 下書きフォルダから開くとき、Mac に保存した下書きの番号 (T23a)。
    var localDraftID: UUID?
    var id = UUID()

    static func new() -> ComposeRequest {
        ComposeRequest(kind: .new)
    }

    static func editingDraft(_ draftID: UUID) -> ComposeRequest {
        ComposeRequest(kind: .new, localDraftID: draftID)
    }

    static func restoring(_ draftID: UUID) -> ComposeRequest {
        ComposeRequest(kind: .new, restoredDraftID: draftID)
    }

    static func replying(_ kind: Kind, to id: MessageID) -> ComposeRequest {
        ComposeRequest(kind: kind, messageID: id.rawValue)
    }

    var composeKind: ComposeKind {
        switch kind {
        case .new: .new
        case .reply: .reply
        case .replyAll: .replyAll
        case .forward: .forward
        }
    }
}

/// 作成ウィンドウの中身 (T18)。宛先は打った文字のまま持ち、送るときに読む。
@MainActor @Observable
final class ComposeModel {
    /// 差出人。変えると、本文の署名も入れ替える (T25)。
    var accountID: AccountID? {
        didSet {
            guard !isLoading, oldValue != accountID else { return }
            body = Composer.replacingSignature(
                in: body, old: signature(for: oldValue), new: signature(for: accountID), quote: quote
            )
        }
    }
    var to = ""
    var cc = ""
    var bcc = ""
    var showsCcAndBcc = false
    var subject = ""
    var body = ""
    var attachments: [DraftAttachment] = []

    private(set) var accounts: [Account] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var errorMessage: String?
    /// 送り終えたら入る。画面はこれを見てウィンドウを閉じる。
    private(set) var outcome: SendOutcome?

    private var inReplyTo: String?
    private var references: [String] = []
    /// 返信・転送の引用の部分 (署名を入れ直すときの目印)。
    private var quote = ""
    /// アカウントごとの署名 (開いたときに読む)。
    private var signatureTexts: [AccountID: String] = [:]
    private let repository: any MailRepository
    private let signatures: SignatureStore?
    /// 送信を取り消せるよう、送るのを預ける先 (T24)。預けたら true。false (0 秒の設定など) なら、ここですぐ送る。
    private let sendLater: (@MainActor (Draft) async -> Bool)?

    /// 下書きの保存先 (T23a)。nil なら保存しない。
    private let drafts: DraftStore?
    /// 打つのをやめてから保存するまでの時間。
    private let autosaveDelay: Duration
    /// 下書きを保存した・消したときに呼ぶ (下書きフォルダを読み直し、サーバーの写しを置き直す・消す)。
    private let onDraftsChanged: (@MainActor (DraftChange) -> Void)?
    /// この作成ウィンドウの下書きの番号。下書きフォルダから開いたときは、その下書きの番号。
    private(set) var draftID = UUID()
    /// 最後に保存した (または開いたときの) 中身。これと同じなら保存しない。
    private var savedContent: DraftContent?
    /// 下書きを保存したことがあるか (送ったとき・捨てたときに消すため)。
    private var hasStoredDraft = false
    /// このウィンドウを開いてから保存したか (閉じたときに、サーバーに置き直すため)。
    private var savedSinceOpening = false
    /// 送った・捨てたあとは、もう保存しない。
    private var isFinished = false
    private var autosaveTask: Task<Void, Never>?

    init(
        repository: any MailRepository, signatures: SignatureStore? = nil,
        sendLater: (@MainActor (Draft) async -> Bool)? = nil,
        drafts: DraftStore? = nil, autosaveDelay: Duration = .seconds(2),
        onDraftsChanged: (@MainActor (DraftChange) -> Void)? = nil
    ) {
        self.repository = repository
        self.signatures = signatures
        self.sendLater = sendLater
        self.drafts = drafts
        self.autosaveDelay = autosaveDelay
        self.onDraftsChanged = onDraftsChanged
    }

    // MARK: - 下書き (T23a)

    /// いまの中身 (宛先は打った文字のまま)。
    var content: DraftContent {
        DraftContent(
            accountID: accountID, to: to, cc: cc, bcc: bcc, subject: subject, body: body,
            attachments: attachments, inReplyTo: inReplyTo, references: references, quote: quote
        )
    }

    /// 中身が変わった。打つのをやめて `autosaveDelay` たったら保存する。
    func contentChanged() {
        guard !isLoading, !isFinished, drafts != nil else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.saveDraft()
        }
    }

    /// 開いたときから変わっていれば、いま保存する。
    func saveDraft() async {
        guard let drafts, !isFinished, !isLoading else { return }
        let current = content
        guard current != savedContent else { return }
        do {
            try await drafts.save(current, id: draftID)
            savedContent = current
            hasStoredDraft = true
            savedSinceOpening = true
            onDraftsChanged?(.saved(draftID))
        } catch {
            errorMessage = "下書きを保存できませんでした: \(error.localizedDescription)"
        }
    }

    /// ウィンドウを閉じるとき: 書きかけなら待たずに保存する。
    /// 開いてから保存していれば、サーバーにも置いてもらう (T23b。打つたびではなく、閉じたときだけ)。
    func closing() async {
        autosaveTask?.cancel()
        await saveDraft()
        guard savedSinceOpening, hasStoredDraft, !isFinished else { return }
        savedSinceOpening = false
        onDraftsChanged?(.closed(draftID))
    }

    /// 「下書きを捨てる」。保存した下書きを消し、もう保存しない。
    func discardDraft() async {
        await finishDraft()
    }

    /// 送った・捨てたとき: 自動保存をやめ、保存した下書きを消す。
    private func finishDraft() async {
        isFinished = true
        autosaveTask?.cancel()
        guard let drafts, hasStoredDraft else { return }
        try? await drafts.delete(draftID)
        hasStoredDraft = false
        // サーバーの写しは、最後に保存したときの差出人のアカウントにある (保存したときにだけ置くため)
        onDraftsChanged?(.removed(draftID, savedContent?.accountID))
    }

    private func signature(for id: AccountID?) -> String {
        id.flatMap { signatureTexts[$0] } ?? ""
    }

    /// 依頼に合わせて中身を作る。返信・転送では元のメールを読み、宛先・件名・引用を入れる。
    /// `restored` があれば (送信を取り消した・送れなかった)、その中身をそのまま入れる (T24)。
    func load(_ request: ComposeRequest, defaultAccount: AccountID? = nil, restored: Draft? = nil) async {
        isLoading = true
        defer { isLoading = false }
        accounts = (try? await repository.accounts()) ?? []
        let fallback = defaultAccount ?? accounts.first?.id
        // 開いたときの中身を「保存済み」とみなす。ただし取り消した・送れなかったメールは、閉じたら下書きに残す
        defer { savedContent = restored == nil ? content : nil }
        // 下書きフォルダから開いた (T23a): 保存した中身をそのまま入れ、同じ下書きに上書きしていく
        if let localID = request.localDraftID, let saved = await drafts?.draft(localID) {
            signatureTexts = await signatures?.all() ?? [:]
            draftID = localID
            hasStoredDraft = true
            fill(from: saved.content, fallbackAccount: fallback)
            return
        }
        if let restored {
            signatureTexts = await signatures?.all() ?? [:]
            fill(from: restored, fallbackAccount: fallback)
            return
        }
        var source: ReplySource?
        if request.kind != .new, let raw = request.messageID {
            do {
                source = try await repository.replySource(for: MessageID(raw))
            } catch {
                errorMessage = "元のメールを読めませんでした。\n\(Self.describe(error))"
            }
        }
        signatureTexts = await signatures?.all() ?? [:]
        let sender = request.kind == .new ? fallback : (source?.accountID ?? fallback)
        let draft = Composer.draft(
            request.composeKind, replyingTo: source, myAddresses: accounts.map(\.emailAddress), defaultAccount: fallback,
            signature: signature(for: sender)
        )
        fill(from: draft, fallbackAccount: fallback)
    }

    /// 保存した下書きの中身を欄に入れる (宛先は打った文字のまま)。
    private func fill(from saved: DraftContent, fallbackAccount fallback: AccountID?) {
        fill(from: saved.draft, fallbackAccount: fallback)
        to = saved.to
        cc = saved.cc
        bcc = saved.bcc
        showsCcAndBcc = !saved.cc.isEmpty || !saved.bcc.isEmpty
    }

    /// 下書きの中身を欄に入れる (読み込み中に呼ぶので、差出人を入れても署名は入れ替えない)。
    private func fill(from draft: Draft, fallbackAccount fallback: AccountID?) {
        accountID = draft.accountID ?? fallback
        to = Composer.format(draft.to)
        cc = Composer.format(draft.cc)
        bcc = Composer.format(draft.bcc)
        showsCcAndBcc = !draft.cc.isEmpty || !draft.bcc.isEmpty
        subject = draft.subject
        body = draft.body
        attachments = draft.attachments
        inReplyTo = draft.inReplyTo
        references = draft.references
        quote = draft.quote
    }

    /// 打った宛先を読み、送れる形にする。読めない宛先があれば `invalidAddress`。
    func makeDraft() throws(DraftProblem) -> Draft {
        var contacts: [[Contact]] = []
        for field in [to, cc, bcc] {
            let parsed = Composer.parseRecipients(field)
            if let invalid = parsed.invalid.first { throw .invalidAddress(invalid) }
            contacts.append(parsed.contacts)
        }
        let draft = Draft(
            accountID: accountID, to: contacts[0], cc: contacts[1], bcc: contacts[2],
            subject: subject, body: body, attachments: attachments, inReplyTo: inReplyTo, references: references,
            quote: quote
        )
        if let problem = Composer.problem(in: draft) { throw problem }
        return draft
    }

    var canSend: Bool {
        !isSending && !isLoading && outcome == nil
    }

    /// 送る。問題があれば送らずに知らせる。
    func send() async {
        guard canSend else { return }
        errorMessage = nil
        let draft: Draft
        do {
            draft = try makeDraft()
        } catch {
            errorMessage = Self.describe(error)
            return
        }
        isSending = true
        defer { isSending = false }
        // 取り消せるよう預けたら、もう送ったものとしてウィンドウを閉じる
        if let sendLater, await sendLater(draft) {
            outcome = .sent
            await finishDraft()
            return
        }
        do {
            outcome = try await repository.send(draft)
            await finishDraft()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func addAttachment(filename: String, mimeType: String, data: Data) {
        attachments.append(DraftAttachment(filename: filename, mimeType: mimeType, data: data))
    }

    func removeAttachment(_ id: DraftAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    var windowTitle: String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? "新規メッセージ" : subject
    }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let problem as DraftProblem:
            switch problem {
            case .noAccount: return "差出人のアカウントを選んでください。"
            case .noRecipients: return "宛先を入れてください。"
            case let .invalidAddress(text): return "「\(text)」はメールアドレスとして読めません。"
            case let .attachmentsTooLarge(bytes):
                let megabytes = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                let limit = ByteCountFormatter.string(fromByteCount: Int64(Composer.maxAttachmentBytes), countStyle: .file)
                return "添付ファイルが大きすぎます (合計 \(megabytes))。\(limit) までにしてください。"
            }
        case let error as SMTPError:
            return error.description
        case let error as AccountError:
            return error.userMessage
        case MailRepositoryError.actionUnavailable:
            return "見本のメールでは送れません。左上の「＋」からアカウントを追加してください。"
        case let error as MailRepositoryError:
            return "送れませんでした (\(error))。"
        case let error as MIMEBuildError:
            return error.description
        default:
            return "送れませんでした: \(error)"
        }
    }
}

/// 作成ウィンドウの下書きに起きたこと (T23b)。サーバーの下書きフォルダの写しを置き直す・消すのに使う。
enum DraftChange: Equatable {
    /// Mac に保存した (打っている間の自動保存。サーバーには置かない)。
    case saved(UUID)
    /// 保存した下書きのウィンドウを閉じた。サーバーに置く。
    case closed(UUID)
    /// Mac から消した (送った・捨てた)。アカウントは、サーバーに写しを置いたはずの差出人。
    case removed(UUID, AccountID?)
}
