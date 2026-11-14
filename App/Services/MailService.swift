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

    init(
        directory: AccountDirectory, store: any MessageStore, watchesForNewMail: Bool = false,
        notifications: NotificationHooks = .none,
        signatures: SignatureStore = SignatureStore(storage: InMemoryAccountListStorage())
    ) {
        self.directory = directory
        self.signatures = signatures
        self.store = store
        self.watchesForNewMail = watchesForNewMail
        self.notifications = notifications
        engine = SyncEngine(store: store)
    }

    /// アプリで使う組み合わせ: アカウント一覧は UserDefaults、パスワードはキーチェーン。新着を見張る。
    static func live() -> MailService {
        let notifier = NotificationService.shared
        let service = MailService(
            directory: AccountDirectory(storage: UserDefaultsAccountListStorage(), secrets: KeychainSecretStore()),
            store: makeLiveStore(),
            watchesForNewMail: true,
            notifications: NotificationHooks(
                prepare: { notifier.start() },
                isEnabled: { NotificationService.isEnabled() },
                post: { notifier.post($0) }
            ),
            signatures: .live()
        )
        notifier.onOpen = { [weak service] id in service?.requestOpen(id) }
        return service
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
        return LiveMailRepository(
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
