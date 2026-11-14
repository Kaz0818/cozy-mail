/// Dock のアイコンに出す未読数の文字を決める (T30、US-9)。
/// 画面 (AppKit) から切り離してあるので、Linux でもテストできる。
public enum DockBadge {
    /// バッジが長くなりすぎないよう、これを超えたら「999+」にする。
    public static let cap = 999

    /// 未読数が 1 以上のときだけ文字を返す。0・負の数・見本のメールを出しているときは nil (何も出さない)。
    public static func label(unreadCount: Int, isShowingSamples: Bool) -> String? {
        guard !isShowingSamples, unreadCount > 0 else { return nil }
        return unreadCount > cap ? "\(cap)+" : String(unreadCount)
    }
}
