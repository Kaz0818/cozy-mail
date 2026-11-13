import SwiftUI

/// 差出人の丸いアイコン。名前の頭文字と、名前から決まる淡い色。
struct AvatarView: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Text(Self.initials(for: name))
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Palette.onAccentFill)
            .frame(width: size, height: size)
            .background(Self.tint(for: name).gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// 日本語の名前は姓 (最初の空白まで、最大 2 文字)、それ以外は最初の 1 文字。
    static func initials(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if first.isASCII { return String(first).uppercased() }
        let familyName = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return String(familyName.prefix(2))
    }

    /// 名前ごとに毎回同じ色になるよう、文字コードの合計で選ぶ。
    private static func tint(for name: String) -> Color {
        let tints: [Color] = [
            Palette.brand, Color(red: 0.72, green: 0.80, blue: 0.93), Color(red: 0.80, green: 0.76, blue: 0.92),
            Color(red: 0.93, green: 0.80, blue: 0.74), Color(red: 0.78, green: 0.88, blue: 0.78),
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return tints[sum % tints.count]
    }
}

#Preview("アイコン") {
    HStack {
        AvatarView(name: "山田 さくら")
        AvatarView(name: "Google")
        AvatarView(name: "プロジェクトチーム")
    }
    .padding()
}
