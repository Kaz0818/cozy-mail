import Foundation
import MailStore
import Observation

/// 3 列の画面の状態。データは `MailRepository` から取り、仮データと本物を差し替えられる。
@MainActor @Observable
final class InboxModel {
    struct AccountItem: Identifiable {
        let account: Account
        let unreadCount: Int
        var id: AccountID { account.id }
    }

    struct FolderItem: Identifiable {
        let role: MailboxRole
        /// 受信トレイ・未読は未読数、下書きは件数。
        let badge: Int
        var id: MailboxRole { role }
    }

    private(set) var accounts: [AccountItem] = []
    private(set) var folders: [FolderItem] = []
    private(set) var unifiedUnreadCount = 0
    private(set) var messages: [MessageSummary] = []
    private(set) var selection: MailboxSelection = .unified(.inbox)
    private(set) var filter: MessageFilter = .all
    private(set) var selectedMessageID: MessageID?
    private(set) var selectedBody: MessageBody?
    private(set) var errorMessage: String?
    /// アカウントがまだ 1 つもなく、見本のメールを出しているとき。
    private(set) var isShowingSamples = false

    private var repository: any MailRepository

    init(repository: any MailRepository, isShowingSamples: Bool = false) {
        self.repository = repository
        self.isShowingSamples = isShowingSamples
    }

    /// データの出どころを差し替えて読み直す (アカウントを追加・削除したとき、同期が終わったとき)。
    /// 選んでいたアカウントがなくなっていたら、統合受信トレイに戻す。
    func use(_ repository: any MailRepository, showingSamples: Bool) async {
        self.repository = repository
        isShowingSamples = showingSamples
        let accounts = (try? await repository.accounts()) ?? []
        if let accountID = selection.accountID, !accounts.contains(where: { $0.id == accountID }) {
            selection = .unified(.inbox)
        }
        await load()
    }

    static let folderOrder: [MailboxRole] = [.inbox, .starred, .unread, .sent, .drafts, .archive, .junk, .trash]

    // MARK: - 読み込み

    func load() async {
        do {
            var items: [AccountItem] = []
            for account in try await repository.accounts() {
                items.append(AccountItem(account: account, unreadCount: try await repository.unreadCount(in: .account(account.id, .inbox))))
            }
            accounts = items
            var folderItems: [FolderItem] = []
            for role in Self.folderOrder {
                let badge = role == .drafts
                    ? try await repository.messages(in: .unified(.drafts), filter: .all).count
                    : (role == .inbox || role == .unread ? try await repository.unreadCount(in: .unified(role)) : 0)
                folderItems.append(FolderItem(role: role, badge: badge))
            }
            folders = folderItems
            unifiedUnreadCount = try await repository.unreadCount(in: .unified(.inbox))
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func select(_ newSelection: MailboxSelection) async {
        guard newSelection != selection else { return }
        selection = newSelection
        await reloadMessages()
    }

    func setFilter(_ newFilter: MessageFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await reloadMessages()
    }

    func selectMessage(_ id: MessageID?) async {
        selectedMessageID = id
        selectedBody = nil
        guard let id else { return }
        do {
            let body = try await repository.body(for: id)
            if selectedMessageID == id { selectedBody = body }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func reloadMessages() async {
        do {
            messages = try await repository.messages(in: selection, filter: filter)
            let keepSelection = selectedMessageID.map { id in messages.contains { $0.id == id } } ?? false
            if !keepSelection { await selectMessage(messages.first?.id) }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - 表示用

    var selectedMessage: MessageSummary? {
        messages.first { $0.id == selectedMessageID }
    }

    var title: String {
        Self.folderName(selection.role)
    }

    var subtitle: String {
        let scope: String
        let unread: Int
        if let accountID = selection.accountID, let item = accounts.first(where: { $0.id == accountID }) {
            scope = item.account.displayName
            unread = item.unreadCount
        } else {
            scope = "すべてのアカウント"
            unread = unifiedUnreadCount
        }
        return "\(scope)・\(unread)件の未読"
    }

    func accountName(for message: MessageSummary) -> String {
        accounts.first { $0.id == message.accountID }?.account.displayName ?? ""
    }

    static func folderName(_ role: MailboxRole) -> String {
        switch role {
        case .inbox: "受信トレイ"
        case .starred: "スター付き"
        case .unread: "未読"
        case .sent: "送信済み"
        case .drafts: "下書き"
        case .archive: "アーカイブ"
        case .junk: "迷惑メール"
        case .trash: "ゴミ箱"
        }
    }

    static func folderSymbol(_ role: MailboxRole) -> String {
        switch role {
        case .inbox: "tray"
        case .starred: "star"
        case .unread: "envelope.badge"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .junk: "xmark.bin"
        case .trash: "trash"
        }
    }
}
