import SwiftUI

/// ティファニーブルーの、立体的な液体の波の背景 (見本の画像の奥にある模様)。
/// ガラスのパネルは後ろにあるものを透かしてゆがめることで質感が出るので、形と明暗がはっきり見える背景にする。
/// 「視差効果を減らす」が有効なら止め、「透明度を下げる」が有効なら単色のグラデーションにする。
struct AppBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                LinearGradient(colors: [Palette.backgroundTop, Palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
            } else if reduceMotion {
                LiquidWaves(time: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    LiquidWaves(time: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 下地の網目グラデーションの上に、ぼかした艶のある「しずく」をいくつか重ねて、液体の膨らみに見せる。
private struct LiquidWaves: View {
    let time: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                base
                ForEach(Self.blobs.indices, id: \.self) { index in
                    blob(Self.blobs[index], in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func wobble(_ speed: Double, _ phase: Double, _ amount: Double = 0.06) -> Float {
        Float(sin(time * speed + phase) * amount)
    }

    /// 明るいところと深いところが交互に来る 4×4 の網目。
    private var base: some View {
        MeshGradient(
            width: 4,
            height: 4,
            points: [
                [0, 0], [0.33, 0], [0.66, 0], [1, 0],
                [0, 0.33], [0.33 + wobble(0.10, 0), 0.33 + wobble(0.08, 1)], [0.66 + wobble(0.07, 2), 0.33], [1, 0.33],
                [0, 0.66], [0.33, 0.66 + wobble(0.09, 3)], [0.66 + wobble(0.11, 4), 0.66 + wobble(0.06, 5)], [1, 0.66],
                [0, 1], [0.33, 1], [0.66, 1], [1, 1],
            ],
            colors: [
                Palette.backgroundTop, Palette.brand, Palette.waveDeep, Palette.backgroundBottom,
                Palette.brand, Palette.waveGlow.opacity(0.9), Palette.brand, Palette.waveDeep,
                Palette.waveDeep, Palette.brand, Palette.waveGlow.opacity(0.7), Palette.brand,
                Palette.backgroundBottom, Palette.waveDeep, Palette.brand, Palette.backgroundTop,
            ],
            smoothsColors: true
        )
    }

    private struct Blob {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let angle: Double
        let speed: Double
    }

    /// 位置と大きさはウィンドウに対する割合。
    private static let blobs = [
        Blob(x: 0.15, y: 0.25, width: 0.55, height: 0.32, angle: -24, speed: 0.13),
        Blob(x: 0.78, y: 0.18, width: 0.5, height: 0.28, angle: 18, speed: 0.09),
        Blob(x: 0.55, y: 0.78, width: 0.7, height: 0.34, angle: -12, speed: 0.11),
        Blob(x: 0.05, y: 0.9, width: 0.4, height: 0.25, angle: 30, speed: 0.07),
    ]

    /// 艶のあるしずく: 上が光り、下が深い色の楕円を、強くぼかす。
    private func blob(_ blob: Blob, in size: CGSize) -> some View {
        let drift = sin(time * blob.speed + blob.x * 10) * 0.03
        return Capsule()
            .fill(LinearGradient(
                colors: [Palette.waveGlow.opacity(0.85), Palette.brand.opacity(0.7), Palette.waveDeep.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: size.width * blob.width, height: size.height * blob.height)
            .rotationEffect(.degrees(blob.angle + drift * 100))
            .position(x: size.width * (blob.x + drift), y: size.height * (blob.y - drift))
            .blur(radius: min(size.width, size.height) * 0.06)
    }
}

#Preview("背景") {
    AppBackground().frame(width: 900, height: 560)
}
