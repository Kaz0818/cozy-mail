import SwiftUI

/// ガラスの部品 (SPEC 8.1)。
///
/// - ガラス (`glassEffect`) にするのは、背景の波の上に浮かぶ大きなパネルだけ。
///   ガラスの上にガラスを重ねると濁って見えるので、パネルの中の行やボタンは「つやのある膨らみ」(`bubble`) で表す。
/// - 「透明度を下げる」が有効なら、ガラスの代わりに不透明な面にする。
extension View {
    /// 背景の上に浮かぶ大きなパネル。縁の光と、やわらかい影を付ける。
    func glassPanel(cornerRadius: CGFloat = Metrics.panelRadius) -> some View {
        modifier(FloatingGlassPanel(cornerRadius: cornerRadius))
    }

    /// 選択中の行。選ばれていなければ何も付けない。
    func selectionGlass(isSelected: Bool, cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(Bubble(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            style: isSelected ? .prominent : .none
        ))
    }

    /// カプセル形の膨らみ (タブ、小さなボタン)。`isProminent` ならティファニーブルーにする。
    func glassCapsule(isProminent: Bool = false) -> some View {
        modifier(Bubble(shape: Capsule(), style: isProminent ? .prominent : .regular))
    }

    /// 角の丸い四角の膨らみ (添付ファイルのカードなど)。
    func glassCard(cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(Bubble(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), style: .regular))
    }
}

/// 縁の光: 左上が明るく、右下に向かって消える。ガラスの厚みと艶を出す。
private struct Rim<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shape.strokeBorder(
            LinearGradient(
                colors: [
                    .white.opacity((colorScheme == .dark ? 0.35 : 0.9) * strength),
                    .white.opacity((colorScheme == .dark ? 0.06 : 0.25) * strength),
                    .white.opacity((colorScheme == .dark ? 0.12 : 0.4) * strength),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
        .allowsHitTesting(false)
    }
}

private struct FloatingGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                content.background(Palette.panel, in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        }
        .overlay(Rim(shape: shape))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 30, y: 16)
    }
}

private struct Bubble<S: InsettableShape>: ViewModifier {
    enum Style {
        case none
        case regular
        case prominent
    }

    let shape: S
    let style: Style
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .none:
            content
        case .regular:
            content
                .background(shape.fill(.white.opacity(colorScheme == .dark ? 0.08 : 0.5)))
                .overlay(Rim(shape: shape, strength: 0.8))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.06), radius: 6, y: 3)
        case .prominent:
            content
                .background(
                    shape.fill(LinearGradient(
                        colors: [Palette.accentFill.opacity(0.85), Palette.accentFill],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    // 上半分の艶
                    .overlay(shape.fill(LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.18 : 0.45), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )))
                )
                .overlay(Rim(shape: shape))
                .shadow(color: Palette.accentFill.opacity(colorScheme == .dark ? 0.45 : 0.6), radius: 10, y: 4)
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
    VStack(alignment: .leading, spacing: 16) {
        Text("選択中の行").padding(12).frame(maxWidth: .infinity, alignment: .leading).selectionGlass(isSelected: true)
        HStack {
            Text("すべて").padding(.horizontal, 16).padding(.vertical, 6).glassCapsule(isProminent: true)
            Text("未読").padding(.horizontal, 16).padding(.vertical, 6).glassCapsule()
            CountBadge(count: 22, isProminent: true)
            CountBadge(count: 7)
        }
    }
    .padding(24)
    .glassPanel()
    .padding(40)
    .frame(width: 460)
    .background(AppBackground())
}
