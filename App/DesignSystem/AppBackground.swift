import SwiftUI

/// ティファニーブルーの柔らかい波の背景 (見本の画像の奥にある模様)。
/// 「視差効果を減らす」が有効なら止め、「透明度を下げる」が有効なら単色のグラデーションにする。
struct AppBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
            } else if reduceMotion {
                waves(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    waves(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// 3×3 の網目の内側の点をゆっくり揺らして、波が動いているように見せる。
    private func waves(time: TimeInterval) -> some View {
        let wobble = { (speed: Double, phase: Double) in Float(sin(time * speed + phase) * 0.08) }
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + wobble(0.11, 0), 0], [1, 0],
                [0, 0.5 + wobble(0.09, 1)], [0.5 + wobble(0.07, 2), 0.5 + wobble(0.13, 3)], [1, 0.5 + wobble(0.1, 4)],
                [0, 1], [0.5 + wobble(0.12, 5), 1], [1, 1],
            ],
            colors: [
                Palette.backgroundTop, Palette.brand.opacity(0.55), Palette.backgroundTop,
                Palette.brand.opacity(0.35), Palette.backgroundBottom, Palette.brand.opacity(0.6),
                Palette.backgroundBottom, Palette.brand.opacity(0.45), Palette.backgroundTop,
            ]
        )
    }
}

#Preview("背景") {
    AppBackground().frame(width: 600, height: 400)
}
