import Testing
@testable import MailStore

/// Dock のアイコンに出す未読数 (T30、US-9)。
@Suite struct DockBadgeTests {
    @Test func showsTheUnreadCount() {
        #expect(DockBadge.label(unreadCount: 1, isShowingSamples: false) == "1")
        #expect(DockBadge.label(unreadCount: 22, isShowingSamples: false) == "22")
    }

    @Test func showsNothingWhenThereIsNoUnreadMail() {
        #expect(DockBadge.label(unreadCount: 0, isShowingSamples: false) == nil)
    }

    @Test func showsNothingForANegativeCount() {
        #expect(DockBadge.label(unreadCount: -3, isShowingSamples: false) == nil)
    }

    /// 見本のメールは本物ではないので、数を出さない。
    @Test func showsNothingForSampleMail() {
        #expect(DockBadge.label(unreadCount: 22, isShowingSamples: true) == nil)
    }

    @Test func capsLargeCounts() {
        #expect(DockBadge.label(unreadCount: 999, isShowingSamples: false) == "999")
        #expect(DockBadge.label(unreadCount: 1000, isShowingSamples: false) == "999+")
        #expect(DockBadge.label(unreadCount: 52_000, isShowingSamples: false) == "999+")
    }
}
