import AppKit
import SwiftUI

/// 色のトークン (SPEC 8.2)。画面のコードでは色の値を直接書かず、必ずここを通す。
struct ColorToken: Sendable, Hashable, CustomTestStringConvertible {
    let light: UInt32
    let dark: UInt32

    var testDescription: String {
        String(format: "#%06X / #%06X", light, dark)
    }

    /// ティファニーブルー。ロゴ、背景の波、ガラスの色付け。
    static let brand = ColorToken(light: 0x81D8D0, dark: 0x81D8D0)
    /// ボタンの文字、リンク、未読の点。
    static let accent = ColorToken(light: 0x08736D, dark: 0x6FD3CA)
    /// 選択中の行、メインのボタン。
    static let accentFill = ColorToken(light: 0x81D8D0, dark: 0x1F7A74)
    /// `accentFill` の上の文字。
    static let onAccentFill = ColorToken(light: 0x0B2E2C, dark: 0xFFFFFF)
    /// 一番奥の背景のグラデーション (上と下)。
    static let backgroundTop = ColorToken(light: 0xE6F6F4, dark: 0x071C1C)
    static let backgroundBottom = ColorToken(light: 0xCFEFEB, dark: 0x0D2B2A)
    /// 「透明度を下げる」のときにガラスの代わりに使う面。
    static let panel = ColorToken(light: 0xF4FBFA, dark: 0x0F2827)
    static let textPrimary = ColorToken(light: 0x0F1F1E, dark: 0xEAF6F5)
    static let textSecondary = ColorToken(light: 0x4A5F5D, dark: 0x9DB5B2)
}

extension Color {
    /// ライト/ダークで自動的に切り替わる色。
    init(_ token: ColorToken) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? token.dark : token.light)
        })
    }
}

/// 画面のコードから使う名前。`Color(.accent)` ではなく `Palette.accent` と書く。
enum Palette {
    static let brand = Color(.brand)
    static let accent = Color(.accent)
    static let accentFill = Color(.accentFill)
    static let onAccentFill = Color(.onAccentFill)
    static let backgroundTop = Color(.backgroundTop)
    static let backgroundBottom = Color(.backgroundBottom)
    static let panel = Color(.panel)
    static let textPrimary = Color(.textPrimary)
    static let textSecondary = Color(.textSecondary)
    static let destructive = Color.red
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// WCAG 2.x のコントラスト比。
enum ContrastRatio {
    static func between(_ first: UInt32, _ second: UInt32) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 0xFF) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

/// 角の丸みと余白 (SPEC 8.3)。
enum Metrics {
    static let panelRadius: CGFloat = 24
    static let rowRadius: CGFloat = 16
    static let panelPadding: CGFloat = 16
    static let rowSpacing: CGFloat = 4
}
