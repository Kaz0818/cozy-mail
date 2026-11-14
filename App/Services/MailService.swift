import AccountKit
import AccountKitKeychain
import AppKit
import Foundation
import MailStore
import MailStoreSwiftData
import Observation

/// アカウント・同期・保存先をまとめて持ち、画面にデータの出どころを渡す。
///
/// - アカウントが 1 つもないときは見本のメール (`PreviewMailRepository`) を出す。
/// - 受信したメールは Mac の中に SwiftData で保存する (`SwiftDataMessageStore`)。次に起動したときは、すぐに前回の一覧を出し、
///   受信は新しいメールの分だけで済む。一度開いたメールはオフラインでも読める。
@MainActor @Observable
final class MailService {
    /// 新着の通知のつなぎ口 (T20b)。アプリでは Mac の通知センター、テストでは記録だけ。
    struct NotificationHooks {
        /// 起動時に一度だけ呼ぶ (通知の許可を求めるなど)。
        var prepare: @MainActor () -> Void = {}
        /// 設定で通知が入っているか。
        var isEnabled: @MainActor () -> Bool = { false }
        var post: @MainActor ([NewMailAlert]) -> Void = { _ in }

        static let none = NotificationHooks()
    }

    /// 下書きをサーバーの下書きフォルダにも置くつなぎ口 (T23b)。アプリだけ。テストでは記録だけ、見本では使わない。
    struct ServerDraftHooks: Sendable {
        /// 下書きを置く (前に置いたものは置き直す)。
        var upload: @Sendable (SavedDraft) async throws -> Void
        /// このアカウントに置いた、この下書きの写しを消す。
        var remove: @Sendable (UUID, AccountID) async throws -> Void
    }

    /// 通知を押したときに、画面に「このメールを開いて」と頼むもの。`serial` は頼むたびに増える (同じメールを続けて開けるように)。
    struct OpenRequest: Equatable {
        var serial = 0
        /// nil なら統合受信トレイを開くだけ (まとめた通知)。
        var messageID: MessageID?
    }

    private(set) var accounts: [Account] = []
    private(set) var isSyncing = false
    /// 最後の同期で失敗したアカウントの説明。成功したら nil。
    private(set) var syncError: String?
    /// 中身が変わるたびに増える。画面はこれを見て読み直す。
    private(set) var revision = 0

    let directory: AccountDirectory
    /// アカウントごとの署名 (T25)。
    let signatures: SignatureStore
    /// Mac に保存した下書き (T23a)。
    let drafts: DraftStore
    private let store: any MessageStore
    private let engine: SyncEngine
    /// 受信トレイを見張って新着をすぐ取るか (T20a)。アプリだけ。テストと見本では本物のサーバーにつながないよう見張らない。
    private let watchesForNewMail: Bool
    /// アカウントごとの見張りの作業。
    private var watchers: [AccountID: Task<Void, Never>] = [:]
    /// いま同期しているアカウントと、同期中にもう一度頼まれたアカウント (終わったらもう 1 回同期する)。
    private var syncingAccounts: Set<AccountID> = []
    private var resyncRequested: Set<AccountID> = []
    /// スリープから戻ったときの知らせの受け取り口。
    private var wakeObserver: (any NSObjectProtocol)?
    private let notifications: NotificationHooks
    /// 起動して最初の一斉の同期が済んだか。それまでの新着 (閉じていた間にたまった分) は通知しない。
    private var hasFinishedFirstSync = false
    private(set) var openRequest = OpenRequest()
    /// まだ画面が受け取っていない「開いて」。ウィンドウを開いたときに `takePendingOpen()` で 1 回だけ受け取る (T21)。
    private var pendingOpen: OpenRequest?
    /// 開いているメインウィンドウの数 (T21)。0 なら、通知から開くときにウィンドウを開く。
    private(set) var mainWindowCount = 0

    /// 送るのを待っている (まだ取り消せる) メール (T24)。
    struct PendingSend: Identifiable, Equatable {
        let id: UUID
        let subject: String
    }

    /// あとで送ったメールについての知らせ (T24)。送れなかった (開き直せる) か、送れたが「送信済み」に残せなかった。
    struct SendNotice: Identifiable, Equatable {
        let id: UUID
        let subject: String
        let message: String
        /// 送れなかったので、作成ウィンドウで開き直せる。false は「送れたが残せなかった」。
        let canReopen: Bool
    }

    /// 送るのを待っている (「送信を取り消す」を出す) メール。送り始めたら外す。
    private(set) var pendingSends: [PendingSend] = []
    /// 送っている途中のメール (もう取り消せない)。
    private var sendingIDs: Set<UUID> = []
    /// 預けたメールの件名 (知らせに出す)。
    private var subjects: [UUID: String] = [:]
    private(set) var sendNotices: [SendNotice] = []
    /// 取り消した・送れなかったメールの下書き。作成ウィンドウで開き直すときに `takeRestoredDraft` で受け取る。
    private var restoredDrafts: [UUID: Draft] = [:]
    /// サーバーの下書きフォルダに写しを置くか (T23b)。nil なら置かない。
    private let serverDrafts: ServerDraftHooks?
    /// いまサーバーに置いている下書きと、置いている間にまた保存された下書き (終わったら最新のものを置き直す)。
    private var uploadingDrafts: Set<UUID> = []
    private var reuploadDrafts: Set<UUID> = []
    /// 下書きの写しを置いたアカウント (差出人を変えたときに、前のアカウントの写しを消すため)。アプリを閉じると忘れる。
    private var serverDraftAccounts: [UUID: AccountID] = [:]
    /// 送信を取り消せる秒数 (設定)。0 ならすぐ送る。
    private let undoSendDelay: @MainActor () -> Duration
    @ObservationIgnored private lazy var sendQueue = SendQueue(
        send: { [weak self] draft in
            guard let self else { throw CancellationError() }
            let repository = await self.repository
            return try await repository.send(draft)
        },
        onEvent: { [weak self] event in await self?.handleSendEvent(event) },
        describe: { ComposeModel.describe($0) }
    )

    init(
        directory: AccountDirectory, store: any MessageStore, watchesForNewMail: Bool = false,
        notifications: NotificationHooks = .none,
        signatures: SignatureStore = SignatureStore(storage: InMemoryAccountListStorage()),
        undoSendDelay: @escaping @MainActor () -> Duration = { .zero },
        drafts: DraftStore = DraftStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("CozyMailDrafts-\(UUID().uuidString)")
        ),
        serverDrafts: ServerDraftHooks? = nil
    ) {
        self.directory = directory
        self.signatures = signatures
        self.drafts = drafts
        self.store = store
        self.watchesForNewMail = watchesForNewMail
        self.notifications = notifications
        self.undoSendDelay = undoSendDelay
        self.serverDrafts = serverDrafts
        engine = SyncEngine(store: store)
    }

    /// アプリで使う組み合わせ: アカウント一覧は UserDefaults、パスワードはキーチェーン。新着を見張る。
    static func live() -> MailService {
        let notifier = NotificationService.shared
        let store = makeLiveStore()
        let directory = AccountDirectory(storage: UserDefaultsAccountListStorage(), secrets: KeychainSecretStore())
        // サーバーの下書き (T23b)。アカウントは、アプリが読み込み済みの一覧を使う (`repository` と同じ理由)
        let accounts = LiveAccounts()
        let server = ServerDrafts(
            store: store,
            accounts: { await accounts.list() },
            openSession: { accountID in try await directory.openSession(for: accountID) }
        )
        let service = MailService(
            directory: directory,
            store: store,
            watchesForNewMail: true,
            notifications: NotificationHooks(
                prepare: { notifier.start() },
                isEnabled: { NotificationService.isEnabled() },
                post: { notifier.post($0) }
            ),
            signatures: .live(),
            undoSendDelay: { UndoSendSetting.delay(in: .standard) },
            drafts: makeLiveDrafts(),
            serverDrafts: ServerDraftHooks(
                upload: { try await server.upload($0) },
                remove: { try await server.remove(id: $0, accountID: $1) }
            )
        )
        accounts.service = service
        notifier.onOpen = { [weak service] id in service?.requestOpen(id) }
        return service
    }

    /// `live()` のサーバーの下書きに、読み込み済みのアカウント一覧を渡すためのもの (サービスを作ったあとでつなぐ)。
    @MainActor private final class LiveAccounts: Sendable {
        weak var service: MailService?
        func list() -> [Account] { service?.accounts ?? [] }
    }

    /// 通知が押された。画面にそのメールを開いてもらう。
    func requestOpen(_ id: MessageID?) {
        openRequest = OpenRequest(serial: openRequest.serial + 1, messageID: id)
        pendingOpen = openRequest
    }

    /// まだ受け取っていない「開いて」を受け取る。2 回目からは nil。
    func takePendingOpen() -> OpenRequest? {
        defer { pendingOpen = nil }
        return pendingOpen
    }

    func mainWindowOpened() { mainWindowCount += 1 }
    func mainWindowClosed() { mainWindowCount = max(0, mainWindowCount - 1) }

    /// Mac の中の保存先。開けなかったとき (ファイルが壊れた、ディスクがいっぱいなど) は、前のようにメモリ上で動かす。
    private static func makeLiveStore() -> any MessageStore {
        do {
            return try SwiftDataMessageStore(directory: SwiftDataMessageStore.defaultDirectory())
        } catch {
            return InMemoryMessageStore()
        }
    }

    /// 下書きの保存先: アプリの保存フォルダの Drafts (メールの保存先の隣)。
    private static func makeLiveDrafts() -> DraftStore {
        let base = (try? SwiftDataMessageStore.defaultDirectory().deletingLastPathComponent())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CozyMail")
        return DraftStore(directory: base.appendingPathComponent("Drafts", isDirectory: true))
    }

    /// 下書きを保存した・消した。下書きフォルダを読み直してもらう (T23a)。
    func draftsChanged() {
        revision += 1
    }

    // MARK: - サーバーの下書き (T23b)

    /// 作成ウィンドウで下書きを保存した・閉じた・消した。下書きフォルダを読み直し、サーバーの写しを置き直す・消す。
    /// サーバーに置けなくても、Mac の下書きは残っているので知らせない (次に閉じたときに置き直す)。
    /// 消せなかった写しは覚えておき、同期のあとで消し直す (`retryServerDraftRemovals`)。
    func draftChanged(_ change: DraftChange) async {
        draftsChanged()
        guard let hooks = serverDrafts, !isShowingSamples else { return }
        switch change {
        case .saved:
            // 打っている間の自動保存は Mac だけ (Gmail の 1 日に置ける量に上限があるため)
            return
        case let .closed(id):
            await uploadDraft(id, hooks: hooks)
        case let .removed(id, accountID):
            await removeServerDraft(id, accountID: accountID, hooks: hooks)
        }
    }

    /// 一覧の「削除」で Mac の下書きを消した。サーバーの写しも消す。
    func localDraftDeleted(_ saved: SavedDraft) async {
        await draftChanged(.removed(saved.id, saved.content.accountID))
    }

    /// 保存した下書きの最新の中身を置く。置いている途中に頼まれたら、終わってからもう 1 回だけ置き直す。
    private func uploadDraft(_ id: UUID, hooks: ServerDraftHooks) async {
        guard !uploadingDrafts.contains(id) else {
            reuploadDrafts.insert(id)
            return
        }
        uploadingDrafts.insert(id)
        defer { uploadingDrafts.remove(id) }
        repeat {
            reuploadDrafts.remove(id)
            // 置く直前に読み直す (消したあとなら置かない)
            guard let saved = await drafts.draft(id) else { return }
            let accountID = saved.content.accountID
            // 差出人を変えたら、前のアカウントに置いた写しを先に消す
            if let previous = serverDraftAccounts[id], previous != accountID {
                await removeOrRemember(id, accountID: previous, hooks: hooks)
                serverDraftAccounts[id] = nil
            }
            guard let accountID else { continue }
            serverDraftAccounts[id] = accountID
            // このアカウントに覚えていた「消す」は、もう要らない (置き直したものを消さないように)
            await forgetPendingRemoval(id, accountID: accountID)
            try? await hooks.upload(saved)
        } while reuploadDrafts.contains(id)
    }

    /// サーバーの写しを消す。置いている途中なら、終わるのを待ってから消す (消したあとに置かれないように)。
    private func removeServerDraft(_ id: UUID, accountID: AccountID?, hooks: ServerDraftHooks) async {
        reuploadDrafts.remove(id)
        while uploadingDrafts.contains(id) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var targets: [AccountID] = []
        for candidate in [accountID, serverDraftAccounts[id]] {
            if let candidate, !targets.contains(candidate) { targets.append(candidate) }
        }
        serverDraftAccounts[id] = nil
        for target in targets {
            await removeOrRemember(id, accountID: target, hooks: hooks)
        }
    }

    /// 写しを消す。消せなければ覚えておく (あとで消し直す)。
    private func removeOrRemember(_ id: UUID, accountID: AccountID, hooks: ServerDraftHooks) async {
        do {
            try await hooks.remove(id, accountID)
        } catch {
            try? await drafts.addPendingRemoval(id, accountID: accountID)
        }
    }

    private func forgetPendingRemoval(_ id: UUID, accountID: AccountID) async {
        let list = await drafts.pendingRemovals()
        let kept = list.filter { !($0.id == id && $0.accountID == accountID) }
        guard kept.count != list.count else { return }
        try? await drafts.updatePendingRemovals(kept)
    }

    /// 消し直しをしている途中か (重ねて始めない)。
    private var isRetryingRemovals = false
    /// 消し直す回数の上限。届いたらあきらめる (UIDPLUS がない、アカウントを消したなど、ずっと消せないもののため)。
    static let removalAttemptLimit = 5

    /// 前に消せなかったサーバーの写しを、消し直す。同期のあとに呼ぶ。
    func retryServerDraftRemovals() async {
        guard let hooks = serverDrafts, !isShowingSamples, !isRetryingRemovals else { return }
        isRetryingRemovals = true
        defer { isRetryingRemovals = false }
        let pending = await drafts.pendingRemovals()
        guard !pending.isEmpty else { return }
        var finished: [PendingServerRemoval] = []
        var failed: [PendingServerRemoval] = []
        for item in pending {
            // 同じ下書きを、またこのアカウントで使っている (置き直した) なら、消さない
            if let draft = await drafts.draft(item.id), draft.content.accountID == item.accountID {
                finished.append(item)
                continue
            }
            do {
                try await hooks.remove(item.id, item.accountID)
                finished.append(item)
            } catch {
                failed.append(item)
            }
        }
        // 消し直している間に足されたものは残す
        let same = { (a: PendingServerRemoval, b: PendingServerRemoval) in a.id == b.id && a.accountID == b.accountID }
        let updated = await drafts.pendingRemovals().compactMap { item -> PendingServerRemoval? in
            if finished.contains(where: { same($0, item) }) { return nil }
            guard failed.contains(where: { same($0, item) }) else { return item }
            var next = item
            next.attempts += 1
            return next.attempts >= Self.removalAttemptLimit ? nil : next
        }
        try? await drafts.updatePendingRemovals(updated)
    }

    /// SwiftUI プレビュー用: 何も保存しない。
    static func preview() -> MailService {
        MailService(
            directory: AccountDirectory(storage: InMemoryAccountListStorage(), secrets: InMemorySecretStore()),
            store: InMemoryMessageStore()
        )
    }

    /// 画面が使うデータの出どころ。
    var repository: any MailRepository {
        guard !accounts.isEmpty else { return PreviewMailRepository() }
        let directory = directory
        // 下書きフォルダには、Mac に保存した下書きも出す (T23a)
        let live = LiveMailRepository(
            store: store,
            // アカウントは、このアプリが読み込み済みの最新の一覧を使う。`directory` に聞きに行くと、受信がキーチェーンの確認
            // (「キーチェーンを使おうとしています」) で止まっている間、その後ろで待たされて一覧が出なくなるため。
            // 写しではなく毎回読むので、作成ウィンドウを開いたあとに差出人の名前を変えても、新しい名前で送る。
            accounts: { [weak self] in await self?.accounts ?? [] },
            // 本文の取得と整理の操作は、そのたびにサーバーにつなぎ、終わったら閉じる
            openSession: { accountID in try await directory.openSession(for: accountID) },
            // 送信も、そのたびに送信用のサーバーにつなぎ、送ったら閉じる
            openSender: { accountID in try await directory.openSender(for: accountID) }
        )
        return DraftsMergingRepository(
            base: live, drafts: drafts,
            // 一覧の「削除」で消したら、サーバーの写しも消す (T23b)
            onDelete: { [weak self] saved in await self?.localDraftDeleted(saved) }
        )
    }

    var isShowingSamples: Bool {
        accounts.isEmpty
    }

    // MARK: - 操作

    /// 起動時: アカウントを読み込んで同期し、新着の見張りを始める。
    func start() async {
        notifications.prepare()
        await reloadAccounts()
        await syncAll()
        observeWake()
        restartWatching()
    }

    /// 全アカウントを順に同期する。1 つが失敗しても、ほかは続ける。
    func syncAll() async {
        guard !isSyncing, !accounts.isEmpty else { return }
        isSyncing = true
        var failures: [AccountID: String] = [:]
        for account in accounts {
            // 見張りの同期が走っているアカウントは、それが終わったらもう 1 回同期してもらう
            guard !syncingAccounts.contains(account.id) else {
                resyncRequested.insert(account.id)
                continue
            }
            syncingAccounts.insert(account.id)
            if let failure = await syncOne(account) { failures[account.id] = failure }
            syncingAccounts.remove(account.id)
            // アカウントごとに画面を更新して、終わった分から見えるようにする
            revision += 1
        }
        accountFailures = failures
        isSyncing = false
        hasFinishedFirstSync = true
        // 一斉の同期の間に、見張りから頼まれていた分
        for id in Array(resyncRequested) where !syncingAccounts.contains(id) {
            await sync(accountID: id)
        }
        // 前に消せなかったサーバーの下書きの写しを、消し直す (T23b)
        await retryServerDraftRemovals()
    }

    /// 1 つのアカウントを同期する (新着の知らせを受けたとき)。同期中にまた頼まれたら、
    /// 同時には走らせず、終わってからもう 1 回だけ同期する (その間に届いたメールを取りこぼさないため)。
    func sync(accountID id: AccountID) async {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        guard !syncingAccounts.contains(id) else {
            resyncRequested.insert(id)
            return
        }
        syncingAccounts.insert(id)
        repeat {
            resyncRequested.remove(id)
            let failure = await syncOne(account)
            accountFailures[id] = failure
            revision += 1
        } while resyncRequested.contains(id)
        syncingAccounts.remove(id)
    }

    /// アカウントごとの最後の失敗。`syncError` はこれをまとめたもの。
    private var accountFailures: [AccountID: String] = [:] {
        didSet {
            let messages = accounts.compactMap { accountFailures[$0.id] }
            syncError = messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
    }

    /// 1 つのアカウントを同期する。失敗したら、その説明を返す。
    private func syncOne(_ account: Account) async -> String? {
        let session: any MailServerSession
        do {
            session = try await directory.openSession(for: account.id)
        } catch {
            return "\(account.displayName): \(Self.describe(error))"
        }
        var failure: String?
        do {
            let report = try await engine.sync(account: account, session: session)
            notifyNewMail(report.newInboxMessages)
        } catch {
            failure = "\(account.displayName): \(Self.describe(error))"
        }
        await session.close()
        return failure
    }

    /// 新しく受信トレイに来た未読メールを通知する (T20b)。起動直後の最初の同期と、設定で切っているときは出さない。
    private func notifyNewMail(_ messages: [MessageSummary]) {
        guard hasFinishedFirstSync, !messages.isEmpty, notifications.isEnabled() else { return }
        let alerts = NewMailNotifier.alerts(for: messages, accounts: accounts)
        if !alerts.isEmpty { notifications.post(alerts) }
    }

    // MARK: - 新着の見張り (T20a)

    /// アカウントごとの見張りを始め直す (起動・アカウントの追加と削除・スリープから戻ったとき)。
    func restartWatching() {
        stopWatching()
        guard watchesForNewMail else { return }
        let directory = directory
        for account in accounts {
            let id = account.id
            let watcher = NewMailWatcher(
                openSession: { try await directory.openSession(for: id) },
                onChange: { [weak self] in await self?.sync(accountID: id) }
            )
            watchers[id] = Task { await watcher.run() }
        }
    }

    func stopWatching() {
        for task in watchers.values { task.cancel() }
        watchers = [:]
    }

    /// スリープから戻ったら、切れているはずの接続を待たずに、すぐ見張りをつなぎ直す (1 分以内に再開するため)。
    private func observeWake() {
        guard watchesForNewMail, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.restartWatching()
                await self.syncAll()
            }
        }
    }

    /// ログインを確かめてから追加し、そのアカウントを同期する。
    func addAccount(
        email: String, password: String, displayName: String, senderName: String, choice: ProviderChoice
    ) async throws(AccountError) {
        _ = try await directory.add(
            email: email, password: password, displayName: displayName, senderName: senderName, choice: choice
        )
        await reloadAccounts()
        await syncAll()
        restartWatching()
    }

    /// 差出人の名前 (送ったメールで相手に見える名前) を変える。
    func setSenderName(_ name: String, for id: AccountID) async throws(AccountError) {
        try await directory.setSenderName(name, for: id)
        await reloadAccounts()
    }

    /// 署名を保存する (T25)。空なら消す。
    func setSignature(_ signature: String, for id: AccountID) async throws {
        try await signatures.setSignature(signature, for: id)
    }

    /// アカウントを削除する。パスワードと、保存していたメールと、署名も消える。
    func removeAccount(_ id: AccountID) async {
        do {
            try await directory.remove(id, messages: store)
        } catch {
            syncError = Self.describe(error)
        }
        try? await signatures.remove(id)
        await reloadAccounts()
        restartWatching()
    }

    // MARK: - 送信の取り消し (T24)

    /// 取り消せるよう、設定の秒数だけ預けてから送る。預けたら true。
    /// 0 秒の設定と見本のメールのときは預けずに false を返す (作成ウィンドウがその場で送り、失敗もそこで知らせる)。
    func sendLater(_ draft: Draft) async -> Bool {
        let delay = undoSendDelay()
        guard delay > .zero, !isShowingSamples else { return false }
        let id = await sendQueue.enqueue(draft, delay: delay)
        pendingSends.append(PendingSend(id: id, subject: draft.subject))
        subjects[id] = draft.subject
        return true
    }

    /// 送る前なら取り消す。取り消せたら true で、下書きは `takeRestoredDraft(id)` で受け取れる。
    func cancelSend(_ id: UUID) async -> Bool {
        guard let draft = await sendQueue.cancel(id) else { return false }
        pendingSends.removeAll { $0.id == id }
        subjects[id] = nil
        restoredDrafts[id] = draft
        return true
    }

    /// 取り消した・送れなかったメールの下書きを受け取る。2 回目からは nil。
    func takeRestoredDraft(_ id: UUID) -> Draft? {
        restoredDrafts.removeValue(forKey: id)
    }

    func dismissSendNotice(_ id: UUID) {
        sendNotices.removeAll { $0.id == id }
    }

    /// 送るのを待っている・送っている途中のメールがあるか (アプリを終える前に確かめる)。
    var hasPendingSends: Bool {
        !pendingSends.isEmpty || !sendingIDs.isEmpty
    }

    /// 待たずにすぐ送る (アプリを終えるとき)。送り途中のものも終わるまで待つ。
    /// 送れなかったものがあれば false (終えずに、開き直せるよう知らせる)。
    func flushSends() async -> Bool {
        let before = Set(sendNotices.filter(\.canReopen).map(\.id))
        await sendQueue.flush()
        return sendNotices.allSatisfy { !$0.canReopen || before.contains($0.id) }
    }

    private func handleSendEvent(_ event: SendQueue.Event) {
        switch event {
        case let .started(id):
            pendingSends.removeAll { $0.id == id }
            sendingIDs.insert(id)
        case let .sent(id, outcome):
            pendingSends.removeAll { $0.id == id }
            sendingIDs.remove(id)
            defer { subjects[id] = nil }
            if case let .sentButNotSaved(reason) = outcome {
                let subject = subjects[id] ?? ""
                showNotice(SendNotice(
                    id: id, subject: subject,
                    message: "相手には届いていますが、このアカウントの「送信済み」フォルダに残せませんでした。\n\(reason)",
                    canReopen: false
                ))
            }
            // 送信済みのフォルダを読み直す
            Task { await syncAll() }
        case let .failed(id, draft, message):
            pendingSends.removeAll { $0.id == id }
            sendingIDs.remove(id)
            subjects[id] = nil
            restoredDrafts[id] = draft
            showNotice(SendNotice(id: id, subject: draft.subject, message: message, canReopen: true))
        }
    }

    /// 知らせを出す。メインウィンドウを閉じていたら、見えるよう開いてもらう。
    private func showNotice(_ notice: SendNotice) {
        sendNotices.append(notice)
        if mainWindowCount == 0 { requestOpen(nil) }
    }

    private func reloadAccounts() async {
        accounts = (try? await directory.accounts()) ?? []
        revision += 1
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? AccountError { return error.userMessage }
        return String(describing: error)
    }
}

extension AccountError {
    /// 画面に出す説明 (何が悪く、どうすればよいか)。
    var userMessage: String {
        switch self {
        case .invalidAddress:
            "メールアドレスの形が正しくありません。"
        case .emptyPassword:
            "アプリパスワードを入力してください。"
        case .unknownProvider:
            "このアドレスのメールの種類が分かりません。「メールの種類」を選んでください (会社の Google Workspace は「Gmail」)。"
        case .alreadyAdded:
            "このアドレスは、すでに追加されています。"
        case let .wrongPassword(reason):
            "ログインできませんでした。ふだんのパスワードではなく、アプリパスワードを使っているか確認してください。(サーバーの応答: \(reason))"
        case let .cannotConnect(reason):
            "サーバーに接続できませんでした。ネットワークを確認してください。(\(reason))"
        case .notFound:
            "アカウントが見つかりません。"
        case let .storage(reason):
            "保存に失敗しました。(\(reason))"
        }
    }
}
