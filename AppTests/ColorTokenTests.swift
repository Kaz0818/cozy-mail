import SwiftUI
import Testing
@testable import CozyMail

/// SPEC 8.2: 文字と背景の明るさの差が WCAG AA (4.5:1 以上) を満たすこと。
@Suite struct ColorTokenTests {
    private static let textTokens: [(String, ColorToken)] = [
        ("textPrimary", .textPrimary), ("textSecondary", .textSecondary), ("accent", .accent),
    ]
    private static let backgrounds: [(String, ColorToken)] = [
        ("backgroundTop", .backgroundTop), ("backgroundBottom", .backgroundBottom), ("panel", .panel),
    ]

    @Test(arguments: textTokens)
    func textIsReadableOnEveryBackgroundInLightMode(name: String, token: ColorToken) {
        for (backgroundName, background) in Self.backgrounds {
            let ratio = ContrastRatio.between(token.light, background.light)
            #expect(ratio >= 4.5, "\(name) on \(backgroundName) (light) is \(ratio)")
        }
    }

    @Test(arguments: textTokens)
    func textIsReadableOnEveryBackgroundInDarkMode(name: String, token: ColorToken) {
        for (backgroundName, background) in Self.backgrounds {
            let ratio = ContrastRatio.between(token.dark, background.dark)
            #expect(ratio >= 4.5, "\(name) on \(backgroundName) (dark) is \(ratio)")
        }
    }

    @Test func textOnAccentFillIsReadable() {
        #expect(ContrastRatio.between(ColorToken.onAccentFill.light, ColorToken.accentFill.light) >= 4.5)
        #expect(ContrastRatio.between(ColorToken.onAccentFill.dark, ColorToken.accentFill.dark) >= 4.5)
    }

    @Test func contrastRatioMatchesTheWCAGDefinition() {
        #expect(ContrastRatio.between(0x000000, 0xFFFFFF) == 21)
        #expect(ContrastRatio.between(0x777777, 0x777777) == 1)
    }

    @Test func brandIsTiffanyBlue() {
        #expect(ColorToken.brand.light == 0x81D8D0)
    }
}

@Suite struct AppThemeTests {
    @Test func systemThemeFollowsTheOS() {
        #expect(AppTheme.system.appearanceName == nil)
        #expect(AppTheme.light.appearanceName == .aqua)
        #expect(AppTheme.dark.appearanceName == .darkAqua)
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        #expect(AppTheme(rawValue: "sepia") == nil)
        #expect(AppTheme.stored("sepia") == .system)
    }
}
