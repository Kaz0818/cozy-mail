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

    /// アカウントを選んでいるときに出す、そのアカウントの Gmail のラベル (T13)。
    struct LabelItem: Identifiable {
        let name: String
        let unreadCount: Int
        var id: String { name }
    }

    struct FolderItem: Identifiable {
        let role: MailboxRole
        /// 受信トレイ・未読は未読数、下書きは件数。
        let badge: Int
        var id: MailboxRole { role }
    }

    private(set) var accounts: [AccountItem] = []
    private(set) var folders: [FolderItem] = []
    /// 選んでいるアカウントのラベル。統合のフォルダを見ているときは空。
    private(set) var labels: [LabelItem] = []
    private(set) var unifiedUnreadCount = 0
    private(set) var messages: [MessageSummary] = []
    private(set) var selection: MailboxSelection = .unified(.inbox)
    private(set) var filter: MessageFilter = .all
    /// 検索欄の言葉 (T19)。空白だけでないとき、一覧は検索の結果になる。
    private(set) var searchText = ""
    private(set) var selectedMessageID: MessageID?
    private(set) var selectedBody: MessageBody?
    /// 本文を取れなかったときの説明。取れたら nil。
    private(set) var bodyError: String?
    /// 整理の操作 (既読・アーカイブなど) が失敗したときの説明。次の操作で消える。
    private(set) var actionError: String?
    private(set) var errorMessage: String?
    /// アカウントがまだ 1 つもなく、見本のメールを出しているとき。
    private(set) var isShowingSamples = false

    /// Dock のアイコンに出す未読数の文字 (T30)。0・見本のメールのときは nil。
    /// サイドバーの「統合受信トレイ」と同じ数 (`unifiedUnreadCount`) を使う。
    var dockBadgeLabel: String? {
        DockBadge.label(unreadCount: unifiedUnreadCount, isShowingSamples: isShowingSamples)
    }

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
        await refreshCounts()
        await reloadMessages()
    }

    /// アカウント・フォルダの未読数だけを読み直す (一覧と選択はそのまま)。
    private func refreshCounts() async {
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
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshLabels()
    }

    /// 選んでいるアカウントのラベルと、その未読数を読み直す。
    /// 開いていたラベルが Gmail で消されていたら、そのアカウントの受信トレイに戻す。
    private func refreshLabels() async {
        guard let accountID = selection.accountID else {
            labels = []
            return
        }
        do {
            var items: [LabelItem] = []
            for name in try await repository.labels(for: accountID) {
                items.append(LabelItem(name: name, unreadCount: try await repository.unreadCount(in: .label(accountID, name))))
            }
            labels = items
            if let label = selection.label, !items.contains(where: { $0.name == label }) {
                selection = .account(accountID, .inbox)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func select(_ newSelection: MailboxSelection) async {
        // 検索中は、同じフォルダを選んでも検索をやめてそのフォルダを出す
        guard newSelection != selection || isSearching else { return }
        let accountChanged = newSelection.accountID != selection.accountID
        selection = newSelection
        searchText = ""
        if accountChanged { await refreshLabels() }
        await reloadMessages()
    }

    /// 検索欄の言葉が変わった。空にすると、選んでいるフォルダに戻る。
    func search(_ text: String) async {
        guard text != searchText else { return }
        searchText = text
        await reloadMessages()
    }

    var isSearching: Bool {
        !searchText.allSatisfy(\.isWhitespace)
    }

    func setFilter(_ newFilter: MessageFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await reloadMessages()
    }

    func selectMessage(_ id: MessageID?) async {
        selectedMessageID = id
        selectedBody = nil
        bodyError = nil
        guard let id else { return }
        do {
            let body = try await repository.body(for: id)
            guard selectedMessageID == id else { return }
            selectedBody = body
            await markReadOnOpen(id)
            // 初めて本文を取ったメールは、一覧の書き出し (2 行目) が埋まる。その書き出しだけを写す。
            // 一覧そのものは入れ替えない (「未読」で絞っているとき、既読にしたばかりのメールが消えてしまうため)
            if let refreshed = try? await currentMessages(), selectedMessageID == id,
               let fresh = refreshed.first(where: { $0.id == id }) {
                patch(id) { $0.preview = fresh.preview }
            }
        } catch {
            if selectedMessageID == id { bodyError = Self.describe(error, doing: "本文を取得") }
        }
    }

    // MARK: - 整理の操作

    /// 開いたメールを既読にする。
    /// 一覧は読み直さず、その行と未読数だけを変える (「未読」で絞っているとき、読み直すと次のメールが選ばれ、
    /// それも既読になり…と続いてしまうため)。
    private func markReadOnOpen(_ id: MessageID) async {
        guard !isShowingSamples, let message = messages.first(where: { $0.id == id }), !message.isRead else { return }
        do {
            try await repository.perform(.markRead, on: id)
            patch(id) { $0.isRead = true }
            await refreshCounts()
        } catch {
            actionError = Self.describe(error, doing: "既読に")
        }
    }

    /// 既読・スター・アーカイブ・削除・迷惑メール。
    /// フラグの変更は、その行だけを変える。移動 (アーカイブ・削除・迷惑メール) は一覧を読み直す
    /// (選んでいたメールが消えたら、その次のメールを選ぶ。最後のメールだったら、新しい最後のメール)。
    func perform(_ action: MessageAction, on id: MessageID? = nil) async {
        guard !isShowingSamples, let id = id ?? selectedMessageID else { return }
        actionError = nil
        let movedIndex = messages.firstIndex { $0.id == id }
        do {
            try await repository.perform(action, on: id)
            switch action {
            case .markRead: patch(id) { $0.isRead = true }
            case .markUnread: patch(id) { $0.isRead = false }
            case .star: patch(id) { $0.isStarred = true; $0.isFlagged = true }
            case .unstar: patch(id) { $0.isStarred = false; $0.isFlagged = false }
            case .archive, .moveToTrash, .markAsJunk:
                // 選んでいたメールが消えたら、同じ位置のメール (次のメール) を選ぶ
                await reloadMessages(fallbackIndex: movedIndex)
            }
            await refreshCounts()
        } catch {
            actionError = Self.describe(error, doing: Self.actionName(action))
        }
    }

    /// その操作が、いまのメールにできるか (できないボタンは押せないようにする)。
    func canPerform(_ action: MessageAction, on message: MessageSummary?) -> Bool {
        guard !isShowingSamples, let message else { return false }
        switch action {
        case .markRead: return !message.isRead
        case .markUnread: return message.isRead
        case .star: return !message.isStarred
        case .unstar: return message.isStarred
        case .archive: return message.mailbox == .inbox
        case .moveToTrash: return message.mailbox != .trash
        case .markAsJunk: return message.mailbox != .junk
        }
    }

    private func patch(_ id: MessageID, _ change: (inout MessageSummary) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private static func actionName(_ action: MessageAction) -> String {
        switch action {
        case .markRead: "既読に"
        case .markUnread: "未読に"
        case .star: "スターを付けることが"
        case .unstar: "スターを外すことが"
        case .archive: "アーカイブ"
        case .moveToTrash: "削除"
        case .markAsJunk: "迷惑メールに"
        }
    }

    /// 本文の取得をやり直す。
    func retryBody() async {
        await selectMessage(selectedMessageID)
    }

    /// 選んでいるメールの添付ファイルの中身。
    func attachmentData(_ attachment: Attachment) async throws -> Data {
        guard let id = selectedMessageID else { throw MailRepositoryError.attachmentNotFound }
        return try await repository.attachmentData(for: id, index: attachment.index)
    }

    /// `doing` は「本文を取得」「アーカイブ」など。「〜できませんでした。」につながる。
    private static func describe(_ error: any Error, doing: String) -> String {
        switch error {
        case let error as MailRepositoryError:
            switch error {
            case .messageNotFound: "メールが見つかりません。新着メールを受信し直してください。"
            case .bodyUnavailable: "本文を取得できません。"
            case .attachmentNotFound: "添付ファイルが見つかりません。"
            case .actionUnavailable: "見本のメールは操作できません。"
            case .actionNotApplicable: "このメールには、その操作はできません。"
            case let .noFolder(role): "\(folderName(role))のフォルダがサーバーにないため、\(doing)できませんでした。"
            }
        case let error as CustomStringConvertible:
            "\(doing)できませんでした。\(error.description)"
        default:
            "\(doing)できませんでした。"
        }
    }

    /// 一覧を読み直す。選んでいたメールがなくなったら、`fallbackIndex` の位置 (なければ先頭) のメールを選ぶ。
    private func reloadMessages(fallbackIndex: Int? = nil) async {
        do {
            // 文字を打つたびに探すので、待っている間に言葉やフォルダが変わったら、古い結果は使わない
            let request = (selection, filter, searchText)
            let found = try await currentMessages()
            guard request == (selection, filter, searchText) else { return }
            messages = found
            let keepSelection = selectedMessageID.map { id in messages.contains { $0.id == id } } ?? false
            if !keepSelection {
                // 検索で打っている途中に一番上のメールを開くと、読んでいない未読メールまで既読になってしまう。
                // 検索の結果が変わっただけのときは、何も開かない (削除などで消えたときは、次のメールを開く)
                if isSearching && fallbackIndex == nil {
                    await selectMessage(nil)
                    return
                }
                let index = min(fallbackIndex ?? 0, messages.count - 1)
                await selectMessage(messages.indices.contains(index) ? messages[index].id : nil)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// いまの一覧の中身: 検索中なら検索の結果、そうでなければ選んでいるフォルダ。
    private func currentMessages() async throws -> [MessageSummary] {
        if isSearching {
            return try await repository.search(searchText, filter: filter)
        }
        return try await repository.messages(in: selection, filter: filter)
    }

    // MARK: - キーボード操作 (T16)

    /// 一覧の次のメールを選ぶ (`↓` / `J`)。何も選んでいなければ先頭。最後なら何もしない。
    func selectNext() async {
        await moveSelection(by: 1)
    }

    /// 一覧の前のメールを選ぶ (`↑` / `K`)。先頭なら何もしない。
    func selectPrevious() async {
        await moveSelection(by: -1)
    }

    private func moveSelection(by offset: Int) async {
        guard !messages.isEmpty else { return }
        guard let current = messages.firstIndex(where: { $0.id == selectedMessageID }) else {
            await selectMessage(messages.first?.id)
            return
        }
        let target = current + offset
        guard messages.indices.contains(target) else { return }
        await selectMessage(messages[target].id)
    }

    /// 選んでいるメールの既読と未読を入れ替える (`⇧⌘U`)。
    func toggleRead() async {
        guard let message = selectedMessage else { return }
        await perform(message.isRead ? .markUnread : .markRead)
    }

    /// 選んでいるメールのスターを付け外しする (`⇧⌘L` / `S`)。
    func toggleStar() async {
        guard let message = selectedMessage else { return }
        await perform(message.isStarred ? .unstar : .star)
    }

    /// 検索欄に移る合図 (`⌘F`)。数が変わったら、画面が検索欄にカーソルを置く。
    private(set) var searchFocusRequest = 0

    func requestSearchFocus() {
        searchFocusRequest += 1
    }

    // MARK: - 表示用

    var selectedMessage: MessageSummary? {
        messages.first { $0.id == selectedMessageID }
    }

    var title: String {
        if isSearching { return "検索" }
        if let label = selection.label { return label }
        return selection.role.map(Self.folderName) ?? ""
    }

    var subtitle: String {
        if isSearching {
            return "「\(searchText.trimmingCharacters(in: .whitespaces))」・\(messages.count)件"
        }
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

// MARK: - 右クリックのメニュー

/// 行の右クリックのメニューの 1 項目 (画面の部品に依らない、中身だけ)。
enum MessageMenuEntry: Equatable {
    case action(title: String, action: MessageAction, isEnabled: Bool)
    case separator
}

extension InboxModel {
    /// 行の右クリックのメニュー。できない操作は灰色にする (見本のメールでは、すべて灰色)。
    func menuEntries(for message: MessageSummary) -> [MessageMenuEntry] {
        func entry(_ title: String, _ action: MessageAction) -> MessageMenuEntry {
            .action(title: title, action: action, isEnabled: canPerform(action, on: message))
        }
        return [
            message.isRead ? entry("未読にする", .markUnread) : entry("既読にする", .markRead),
            message.isStarred ? entry("スターを外す", .unstar) : entry("スターを付ける", .star),
            .separator,
            entry("アーカイブ", .archive),
            entry("削除", .moveToTrash),
            entry("迷惑メールにする", .markAsJunk),
        ]
    }
}
