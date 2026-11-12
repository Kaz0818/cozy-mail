import SwiftUI

@main
struct CozyMailApp: App {
    @AppStorage(AppTheme.storageKey) private var themeRawValue = AppTheme.system.rawValue

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackground()
                Text("Cozy Mail")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(32)
                    .glassPanel()
            }
            .frame(minWidth: 900, minHeight: 600)
            .onChange(of: themeRawValue, initial: true) {
                AppTheme.stored(themeRawValue).apply()
            }
        }

        Settings {
            TabView {
                Tab("見た目", systemImage: "paintpalette") {
                    AppearanceSettings()
                }
            }
        }
    }
}
