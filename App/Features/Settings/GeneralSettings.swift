import Observation
import ServiceManagement
import SwiftUI

/// ログイン時に起動するかの切り替え口 (T21)。テストでは偽物に差し替える。
@MainActor
protocol LoginItem: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// 本物: macOS の「ログイン項目」(`SMAppService.mainApp`)。
@MainActor
final class SystemLoginItem: LoginItem {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 設定の「ログイン時に起動」の状態。切り替えが断られたら、元の状態のまま理由を出す。
@MainActor @Observable
final class LoginItemSettingsModel {
    private let item: any LoginItem
    private(set) var launchesAtLogin: Bool
    private(set) var errorMessage: String?

    init(item: any LoginItem) {
        self.item = item
        launchesAtLogin = item.isEnabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            try item.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = "切り替えられませんでした。システム設定の「一般」→「ログイン項目」を確かめてください。(\(error.localizedDescription))"
        }
        launchesAtLogin = item.isEnabled
    }
}

/// 設定の「一般」(T21)。
struct GeneralSettings: View {
    @State private var model = LoginItemSettingsModel(item: SystemLoginItem())
    @AppStorage(UndoSendSetting.key) private var undoSeconds = UndoSendSetting.defaultSeconds

    var body: some View {
        Form {
            // 送信の取り消し (T24)
            Picker("送信の取り消し", selection: $undoSeconds) {
                ForEach(UndoSendSetting.choices, id: \.self) { seconds in
                    Text(seconds == 0 ? "すぐ送る (取り消さない)" : "\(seconds) 秒").tag(seconds)
                }
            }
            Text("送信を押してから、この秒数のあいだ「送信を取り消す」が出ます。そのあいだにアプリを終えると、先に送ってから終わります。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("ログイン時に Cozy Mail を開く", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { model.setLaunchesAtLogin($0) }
            ))
            Text("ウィンドウを閉じても、Cozy Mail はメニューバーに残って新着を受け取ります。終わるときはメニューバーの「Cozy Mail を終了」か ⌘Q で。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
