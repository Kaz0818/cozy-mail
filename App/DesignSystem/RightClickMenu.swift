import AppKit
import SwiftUI

/// 右クリックのメニューの 1 項目。
enum ContextMenuEntry {
    case item(String, isEnabled: Bool, action: @MainActor () -> Void)
    case separator
}

extension View {
    /// 右クリック (と control + クリック) で、macOS 標準のメニューを出す。
    ///
    /// SwiftUI の `.contextMenu` は、このアプリのガラスのパネルの中の行では出ないことがあった
    /// (2026-11-13 オーナーの報告)。そのため、AppKit のメニューを直接出す透明な覆いを重ねる。
    /// 左クリック・スクロール・マウスの出入りは覆いを素通りし、下の SwiftUI の行に届く。
    func rightClickMenu(_ entries: [ContextMenuEntry]) -> some View {
        overlay(RightClickMenuArea(entries: entries).accessibilityHidden(true))
    }
}

private struct RightClickMenuArea: NSViewRepresentable {
    let entries: [ContextMenuEntry]

    func makeNSView(context: Context) -> RightClickMenuView {
        RightClickMenuView()
    }

    func updateNSView(_ view: RightClickMenuView, context: Context) {
        view.entries = entries
    }
}

final class RightClickMenuView: NSView {
    var entries: [ContextMenuEntry] = []

    /// メニューを開くクリックのときだけ、自分が受け取る。それ以外は下の行に任せる。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, Self.opensMenu(event) else { return nil }
        return super.hitTest(point)
    }

    static func opensMenu(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            true
        case .leftMouseDown, .leftMouseUp:
            event.modifierFlags.contains(.control)
        default:
            false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case let .item(title, isEnabled, action):
                menu.addItem(ClosureMenuItem(title: title, isEnabled: isEnabled, handler: action))
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control), let menu = menu(for: event) else {
            super.mouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// 選ばれたら、渡された処理を呼ぶメニュー項目。
private final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, isEnabled: Bool, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
