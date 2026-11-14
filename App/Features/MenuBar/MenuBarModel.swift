import AppKit
import MailStore
import Observation

/// メニューバーの中身 (T21)。アプリ全体で 1 つだけあり、ウィンドウを閉じていても動く。
/// Dock のアイコンの未読数 (T30) もここで決める (メインウィンドウを閉じても数が古くならないように)。
@MainActor @Observable
final class MenuBarModel {
    private(set) var summary = MenuBarSummary.empty

    /// Dock のアイコンに出す未読数の文字。メニューバーと同じ数。
    var dockBadgeLabel: String? { summary.countLabel }

    /// 統合受信トレイの未読数と、最近の未読メールを読み直す。
    func refresh(repository: any MailRepository, isShowingSamples: Bool) async {
        guard !isShowingSamples else {
            summary = .empty
            return
        }
        do {
            let count = try await repository.unreadCount(in: .unified(.inbox))
            let unread = try await repository.messages(in: .unified(.inbox), filter: .unread)
            summary = MenuBarSummary(unreadCount: count, unreadMessages: unread, isShowingSamples: false)
        } catch {
            // 読めなかったときは前の数のまま
        }
    }
}
