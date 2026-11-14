import Foundation
import MailStore
import Testing
@testable import CozyMail

/// メニューバー (T21)。Dock の未読数もここで決める (ウィンドウを閉じていても数が正しいように)。
@MainActor @Suite struct MenuBarModelTests {
    @Test func realMailShowsTheUnifiedInboxUnreadCountAndRecentMail() async {
        let model = MenuBarModel()
        await model.refresh(repository: PreviewMailRepository(), isShowingSamples: false)
        #expect(model.summary.countLabel == "22")
        #expect(model.summary.recent.count == 5)
        #expect(model.dockBadgeLabel == "22")
    }

    @Test func samplesShowNoCountAndNoMail() async {
        let model = MenuBarModel()
        await model.refresh(repository: PreviewMailRepository(), isShowingSamples: true)
        #expect(model.summary.countLabel == nil)
        #expect(model.summary.recent.isEmpty)
        #expect(model.dockBadgeLabel == nil)
    }

    @Test func beforeTheFirstRefreshThereIsNothing() {
        #expect(MenuBarModel().dockBadgeLabel == nil)
    }
}

/// ログイン時の起動の切り替え (T21)。本物の `SMAppService` の代わりに偽物を使う。
@MainActor @Suite struct LoginItemSettingsTests {
    final class FakeLoginItem: LoginItem {
        var isEnabled = false
        var failure: (any Error)?
        func setEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            isEnabled = enabled
        }
    }

    struct Refused: Error {}

    @Test func showsTheCurrentStateAndSwitchesIt() {
        let item = FakeLoginItem()
        let model = LoginItemSettingsModel(item: item)
        #expect(model.launchesAtLogin == false)
        model.setLaunchesAtLogin(true)
        #expect(item.isEnabled)
        #expect(model.launchesAtLogin)
        #expect(model.errorMessage == nil)
    }

    /// 断られたら、元の状態に戻して理由を出す。
    @Test func aRefusalKeepsTheOldStateAndExplains() {
        let item = FakeLoginItem()
        item.failure = Refused()
        let model = LoginItemSettingsModel(item: item)
        model.setLaunchesAtLogin(true)
        #expect(model.launchesAtLogin == false)
        #expect(model.errorMessage != nil)
    }
}

/// 通知やメニューから開くメールは、ウィンドウが開いたときに 1 回だけ受け取る (T21)。
@MainActor @Suite struct OpenRequestTests {
    @Test func aPendingRequestIsTakenOnce() {
        let service = MailService.preview()
        #expect(service.takePendingOpen() == nil)
        service.requestOpen(MessageID("a/1"))
        #expect(service.takePendingOpen()?.messageID == MessageID("a/1"))
        #expect(service.takePendingOpen() == nil)
    }

    @Test func countsOpenMainWindows() {
        let service = MailService.preview()
        #expect(service.mainWindowCount == 0)
        service.mainWindowOpened()
        service.mainWindowOpened()
        service.mainWindowClosed()
        #expect(service.mainWindowCount == 1)
    }
}
