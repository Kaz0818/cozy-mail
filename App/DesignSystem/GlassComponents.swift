import SwiftUI

/// ガラスの部品 (SPEC 8.1)。
///
/// - ガラス (`glassEffect`) にするのは、背景の波の上に浮かぶ大きなパネルだけ。
///   ガラスの上にガラスを重ねると濁って見えるので、パネルの中の行やボタンは「つやのある膨らみ」(`Bubble`) で表す。
/// - 高級感は細部で出す: パネル上部の光沢、二重の縁 (外側の影の線 + 内側の光の線)、近い影と遠い影の 2 枚重ね、
///   マウスを乗せたときの反応。
/// - 「透明度を下げる」が有効なら、ガラスの代わりに不透明な面にする。「視差効果を減らす」なら動きを付けない。
extension View {
    /// 背景の上に浮かぶ大きなパネル。
    func glassPanel(cornerRadius: CGFloat = Metrics.panelRadius) -> some View {
        modifier(FloatingGlassPanel(cornerRadius: cornerRadius))
    }

    /// 一覧やサイドバーの行。選ばれているとティファニーブルーに光り、マウスを乗せるとうっすら膨らむ。
    func selectionGlass(isSelected: Bool, cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(SelectableRow(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    /// カプセル形の膨らみ (タブ、小さなボタン)。`isProminent` ならティファニーブルーにする。
    func glassCapsule(isProminent: Bool = false) -> some View {
        modifier(Bubble(shape: Capsule(), style: isProminent ? .prominent : .regular, respondsToHover: true))
    }

    /// 角の丸い四角の膨らみ (添付ファイルのカードなど)。
    func glassCard(cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(Bubble(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            style: .regular,
            respondsToHover: true
        ))
    }
}

// MARK: - 縁

/// 内側の光の線: 左上が明るく、右下に向かって消える。ガラスの厚みと艶を出す。
private struct Rim<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        shape.strokeBorder(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity((isDark ? 0.45 : 0.95) * strength), location: 0),
                    .init(color: .white.opacity((isDark ? 0.08 : 0.3) * strength), location: 0.45),
                    .init(color: .white.opacity((isDark ? 0.18 : 0.5) * strength), location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
        .allowsHitTesting(false)
    }
}

// MARK: - パネル

private struct FloatingGlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        Group {
            if reduceTransparency {
                content.background(Palette.panel, in: shape)
            } else {
                content
                    // パネル上部に当たる光の反射 (上から 1/4 ほどで消える)
                    .background(
                        shape.fill(LinearGradient(
                            stops: [
                                .init(color: .white.opacity(isDark ? 0.10 : 0.38), location: 0),
                                .init(color: .white.opacity(0), location: 0.28),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    )
                    .glassEffect(.regular, in: shape)
            }
        }
        // 二重の縁: 外側の細い影の線で輪郭を締め、内側の光の線で厚みを出す
        .overlay(shape.stroke(.black.opacity(isDark ? 0.55 : 0.10), lineWidth: 0.5).allowsHitTesting(false))
        .overlay(Rim(shape: shape.inset(by: 0.5)))
        // 近い影 (接地感) と遠い影 (浮遊感)
        .shadow(color: .black.opacity(isDark ? 0.35 : 0.08), radius: 3, y: 1)
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.14), radius: 36, y: 22)
    }
}

// MARK: - 膨らみ

private enum BubbleStyle {
    case none
    case hover
    case regular
    case prominent
}

private struct Bubble<S: InsettableShape>: ViewModifier {
    let shape: S
    let style: BubbleStyle
    var respondsToHover = false
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        styled(content, style: effectiveStyle)
            .onHover { hovering in
                guard respondsToHover else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isHovered = hovering }
            }
    }

    private var effectiveStyle: BubbleStyle {
        style == .regular && isHovered ? .hover : style
    }

    @ViewBuilder
    private func styled(_ content: Content, style: BubbleStyle) -> some View {
        let isDark = colorScheme == .dark
        switch style {
        case .none:
            content
        case .regular, .hover:
            let isHover = style == .hover
            content
                .background(shape.fill(.white.opacity(isDark ? (isHover ? 0.16 : 0.08) : (isHover ? 0.7 : 0.5))))
                .overlay(Rim(shape: shape, strength: isHover ? 1 : 0.8))
                .shadow(color: .black.opacity(isDark ? 0.25 : 0.06), radius: isHover ? 8 : 5, y: isHover ? 4 : 2)
        case .prominent:
            content
                .background(
                    shape.fill(LinearGradient(
                        colors: [Palette.brand.opacity(isDark ? 0.55 : 0.9), Palette.accentFill],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    // 上半分の艶
                    .overlay(shape.fill(LinearGradient(
                        colors: [.white.opacity(isDark ? 0.22 : 0.5), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )))
                )
                .overlay(Rim(shape: shape))
                // ティファニーブルーの光がにじむ
                .shadow(color: Palette.brand.opacity(isDark ? 0.45 : 0.55), radius: 14, y: 4)
        }
    }
}

/// 行: 選ばれていればティファニーブルー、マウスが乗っていればうっすら膨らむ、それ以外は何も付けない。
private struct SelectableRow: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .modifier(Bubble(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                style: isSelected ? .prominent : (isHovered ? .hover : .none)
            ))
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isHovered = hovering }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isSelected)
    }
}

// MARK: - バッジ

/// 未読数などを表す小さな丸いバッジ。
struct CountBadge: View {
    let count: Int
    var isProminent = false

    var body: some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(isProminent ? Palette.onAccentFill : Palette.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .modifier(Bubble(shape: Capsule(), style: .regular))
                .accessibilityLabel(Text("未読 \(count) 件"))
        }
    }
}

#Preview("ガラスの部品") {
    VStack(alignment: .leading, spacing: 16) {
        Text("選択中の行").padding(12).frame(maxWidth: .infinity, alignment: .leading).selectionGlass(isSelected: true)
        Text("選ばれていない行").padding(12).frame(maxWidth: .infinity, alignment: .leading).selectionGlass(isSelected: false)
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
