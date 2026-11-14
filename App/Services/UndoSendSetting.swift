import Foundation

/// 送信を取り消せる秒数の設定 (T24、US-15)。0 は「すぐ送る」。
enum UndoSendSetting {
    static let key = "send.undoSeconds"
    static let defaultSeconds = 10
    /// 設定画面で選べる秒数。
    static let choices = [0, 5, 10, 20, 30]

    static func seconds(in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultSeconds }
        return min(max(defaults.integer(forKey: key), 0), choices.max() ?? defaultSeconds)
    }

    static func delay(in defaults: UserDefaults) -> Duration {
        .seconds(seconds(in: defaults))
    }
}
