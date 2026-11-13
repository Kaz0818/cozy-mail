import AppKit
import SwiftUI

/// 見た目のテーマ (US-11)。
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appTheme"

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    /// `nil` は OS の設定に従う。
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    static func stored(_ rawValue: String) -> AppTheme {
        AppTheme(rawValue: rawValue) ?? .system
    }

    /// アプリ全体 (すべてのウィンドウ) に反映する。再起動は要らない。
    @MainActor func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

/// 設定ウィンドウ (`⌘,`) の「見た目」タブ。
struct AppearanceSettings: View {
    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some View {
        Form {
            Picker("テーマ", selection: Binding(
                get: { AppTheme.stored(themeRawValue) },
                set: { themeRawValue = $0.rawValue }
            )) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

#Preview("見た目の設定") {
    AppearanceSettings()
}
