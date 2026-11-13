import SwiftUI

/// ガラスの部品 (SPEC 8.1)。「透明度を下げる」が有効なら、ガラスの代わりに不透明な面にする。
extension View {
    /// 列や窓のような大きな面。
    func glassPanel(cornerRadius: CGFloat = Metrics.panelRadius) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: nil))
    }

    /// 選択中の行。選ばれていなければ何も付けない。
    func selectionGlass(isSelected: Bool, cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(SelectionGlass(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    /// カプセル形のガラス (タブ、小さなボタン)。`isProminent` ならティファニーブルーで色を付ける。
    func glassCapsule(isProminent: Bool = false) -> some View {
        modifier(GlassSurface(shape: Capsule(), tint: isProminent ? Palette.accentFill : nil))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(tint ?? Palette.panel, in: shape)
        } else {
            content.glassEffect(.regular.tint(tint), in: shape)
        }
    }
}

private struct SelectionGlass: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if !isSelected {
            content
        } else if reduceTransparency {
            content.background(Palette.accentFill, in: shape)
        } else {
            content.glassEffect(.regular.tint(Palette.accentFill).interactive(), in: shape)
        }
    }
}

/// 未読数などを表す小さな丸いバッジ。
struct CountBadge: View {
    let count: Int
    var isProminent = false

    var body: some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(isProminent ? Palette.onAccentFill : Palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .glassCapsule(isProminent: isProminent)
                .accessibilityLabel(Text("未読 \(count) 件"))
        }
    }
}

#Preview("ガラスの部品") {
    VStack(spacing: 16) {
        Text("パネル").padding(24).glassPanel()
        Text("選択中の行").padding(12).frame(maxWidth: .infinity, alignment: .leading).selectionGlass(isSelected: true)
        HStack {
            Text("すべて").padding(.horizontal, 16).padding(.vertical, 6).glassCapsule(isProminent: true)
            Text("未読").padding(.horizontal, 16).padding(.vertical, 6).glassCapsule()
            CountBadge(count: 22, isProminent: true)
            CountBadge(count: 7)
        }
    }
    .padding(32)
    .frame(width: 420)
    .background(AppBackground())
}
