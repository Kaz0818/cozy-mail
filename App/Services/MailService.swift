import AccountKit
import AccountKitKeychain
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
    private(set) var accounts: [Account] = []
    private(set) var isSyncing = false
    /// 最後の同期で失敗したアカウントの説明。成功したら nil。
    private(set) var syncError: String?
    /// 中身が変わるたびに増える。画面はこれを見て読み直す。
    private(set) var revision = 0

    let directory: AccountDirectory
    private let store: any MessageStore
    private let engine: SyncEngine

    init(directory: AccountDirectory, store: any MessageStore) {
        self.directory = directory
        self.store = store
        engine = SyncEngine(store: store)
    }

    /// アプリで使う組み合わせ: アカウント一覧は UserDefaults、パスワードはキーチェーン。
    static func live() -> MailService {
        MailService(
            directory: AccountDirectory(storage: UserDefaultsAccountListStorage(), secrets: KeychainSecretStore()),
            store: makeLiveStore()
        )
    }

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
            accounts: { try await directory.accounts() },
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

    /// 起動時: アカウントを読み込んで同期する。
    func start() async {
        await reloadAccounts()
        await syncAll()
    }

    /// 全アカウントを順に同期する。1 つが失敗しても、ほかは続ける。
    func syncAll() async {
        guard !isSyncing, !accounts.isEmpty else { return }
        isSyncing = true
        var failures: [String] = []
        for account in accounts {
            do {
                let session = try await directory.openSession(for: account.id)
                do {
                    _ = try await engine.sync(account: account, session: session)
                } catch {
                    failures.append("\(account.displayName): \(Self.describe(error))")
                }
                await session.close()
            } catch {
                failures.append("\(account.displayName): \(Self.describe(error))")
            }
            // アカウントごとに画面を更新して、終わった分から見えるようにする
            revision += 1
        }
        syncError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        isSyncing = false
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
    }

    /// 差出人の名前 (送ったメールで相手に見える名前) を変える。
    func setSenderName(_ name: String, for id: AccountID) async throws(AccountError) {
        try await directory.setSenderName(name, for: id)
        await reloadAccounts()
    }

    /// アカウントを削除する。パスワードと、保存していたメールも消える。
    func removeAccount(_ id: AccountID) async {
        do {
            try await directory.remove(id, messages: store)
        } catch {
            syncError = Self.describe(error)
        }
        await reloadAccounts()
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
