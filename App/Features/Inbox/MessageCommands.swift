import MailStore
import SwiftUI

extension FocusedValues {
    /// いま前に出ているメインウィンドウの受信トレイ。メニューの項目はこれに対して動く。
    @Entry var inboxModel: InboxModel?
}

/// メニューバーの「ファイル」の新規作成と、「メッセージ」メニュー (SPEC US-8)。
/// 新規メッセージ・返信・全員に返信・転送は、作成ウィンドウ (`ComposeWindow`) を開く。
///
/// 1 文字だけのショートカット (`E` アーカイブ、`⌫` 削除、`↑` `↓` / `J` `K` 前後のメール、`S` スター) は、
/// 文字を打っている欄で誤って動かないよう、メール一覧で受ける (`MessageListKeys`)。
/// メニューには、どこからでも使える `⌘` 付きのショートカットを付ける。
struct MessageCommands: Commands {
    @FocusedValue(\.inboxModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新規メッセージ") { openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.new()) }
                .keyboardShortcut("n")
            Button("新規ウィンドウ") { openWindow(id: CozyMailApp.mainWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("メールを検索") { model?.requestSearchFocus() }
                .keyboardShortcut("f")
                .disabled(model == nil)
        }

        CommandMenu("メッセージ") {
            let message = model?.selectedMessage
            Button("返信") { compose(.reply) }
                .keyboardShortcut("r")
                .disabled(message == nil)
            Button("全員に返信") { compose(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(message == nil)
            Button("転送") { compose(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(message == nil)
            Divider()
            Button("次のメール (↓ または J)") { run { await $0.selectNext() } }
                .disabled(model?.messages.isEmpty ?? true)
            Button("前のメール (↑ または K)") { run { await $0.selectPrevious() } }
                .disabled(model?.messages.isEmpty ?? true)
            Divider()
            Button(message?.isRead == false ? "既読にする" : "未読にする") { run { await $0.toggleRead() } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!can(message?.isRead == false ? .markRead : .markUnread))
            Button(message?.isStarred == true ? "スターを外す (S)" : "スターを付ける (S)") { run { await $0.toggleStar() } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!can(message?.isStarred == true ? .unstar : .star))
            Divider()
            Button("アーカイブ (E)") { run { await $0.perform(.archive) } }
                .keyboardShortcut("a", modifiers: [.command, .control])
                .disabled(!can(.archive))
            // ⌘⌫ は文字を打つ欄では「行の始めまで消す」なので、メニューには付けない (一覧で ⌫)
            Button("削除 (⌫)") { run { await $0.perform(.moveToTrash) } }
                .disabled(!can(.moveToTrash))
            Button("迷惑メールにする") { run { await $0.perform(.markAsJunk) } }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(!can(.markAsJunk))
        }
    }

    private func compose(_ kind: ComposeRequest.Kind) {
        guard let id = model?.selectedMessageID else { return }
        openWindow(id: CozyMailApp.composeWindowID, value: ComposeRequest.replying(kind, to: id))
    }

    private func can(_ action: MessageAction) -> Bool {
        guard let model else { return false }
        return model.canPerform(action, on: model.selectedMessage)
    }

    private func run(_ work: @escaping @MainActor (InboxModel) async -> Void) {
        guard let model else { return }
        Task { await work(model) }
    }
}

/// メール一覧で受ける 1 文字のショートカット (Gmail と同じ `J` `K` `E` `S` も使える)。
/// 一覧にカーソルがあるときだけ動くので、検索欄などで文字を打っても誤って動かない。
struct MessageListKeys: ViewModifier {
    let model: InboxModel

    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            guard let action = Self.action(for: press.key, characters: press.characters) else { return .ignored }
            Task { await action(model) }
            return .handled
        }
    }

    static func action(for key: KeyEquivalent, characters: String) -> (@MainActor (InboxModel) async -> Void)? {
        switch key {
        case .downArrow: return { await $0.selectNext() }
        case .upArrow: return { await $0.selectPrevious() }
        case .delete, .deleteForward: return { await $0.perform(.moveToTrash) }
        default: break
        }
        switch characters.lowercased() {
        case "j": return { await $0.selectNext() }
        case "k": return { await $0.selectPrevious() }
        case "e": return { await $0.perform(.archive) }
        case "s": return { await $0.toggleStar() }
        default: return nil
        }
    }
}
