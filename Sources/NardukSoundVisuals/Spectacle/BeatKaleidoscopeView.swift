#if canImport(SwiftUI)
    import NardukSoundAnalysis
    import SwiftUI

    /// A beat tunnel seen through a kaleidoscope: concentric rings rush toward the viewer on the beat clock
    /// (`travel`), and the spectrum is mirrored into a ring of wedges around them. A drop folds more wedges and spins
    /// faster; calm mode keeps the fold count and drops the spin, so nothing strobes.
    ///
    /// Polls `input` from its own timeline at the budget in `\.soundFramesPerSecond` and advances the shared
    /// `SoundVisualState` (idempotent `update`).
    public struct BeatKaleidoscopeView: View {
        let state: SoundVisualState
        let input: @MainActor () -> SoundVisualInput
        let calm: Bool
        @Environment(\.soundFramesPerSecond) private var framesPerSecond

        public init(
            state: SoundVisualState, calm: Bool = false, input: @escaping @MainActor () -> SoundVisualInput
        ) {
            self.state = state
            self.calm = calm
            self.input = input
        }

        public var body: some View {
            TimelineView(SoundRenderBudget.schedule(framesPerSecond)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: false) { context, size in
                    MainActor.assumeIsolated {
                        state.update(input(), now: now, options: SoundVisualOptions(calm: calm))
                        BeatKaleidoscope.draw(into: &context, size: size, state: state)
                    }
                }
            }
            .background(Color.black)
            .accessibilityHidden(true)
        }
    }

    /// The drawing half, separate so a golden test can render a fixed state.
    @MainActor public enum BeatKaleidoscope {
        /// Wedges in the fold: 6 at rest, 8 in a drop (`dropAmount` blends).
        static func foldCount(_ state: SoundVisualState) -> Int { state.dropAmount > 0.5 ? 8 : 6 }

        public static func draw(into context: inout GraphicsContext, size: CGSize, state: SoundVisualState) {
            let unit = Double(min(size.width, size.height)) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let palette = state.palette
            func color(_ t: Float, _ alpha: Double) -> Color {
                let c = palette.sample(t - t.rounded(.down))
                return Color(
                    .sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: max(0, min(1, alpha)))
            }

            // The tunnel: rings from the beat clock, each born at the center and growing to the edge.
            context.blendMode = .plusLighter
            let ringCount = 9
            let travel = state.travel - state.travel.rounded(.down)
            for i in 0..<ringCount {
                let phase = (Double(i) + travel) / Double(ringCount)
                let radius = unit * 1.15 * phase * phase
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let pulse = 1 + Double(state.kick) * 0.6 * (1 - phase)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(color(Float(phase) * 0.5 + 0.1, (0.15 + 0.6 * phase) * min(pulse, 1.4))),
                    lineWidth: max(1, unit * 0.02 * (0.4 + phase)))
            }

            // The fold: the spectrum mirrored into wedges around the center.
            let folds = foldCount(state)
            let bands = SoundVisualState.bandCount
            let spin = state.calm ? 0 : Double(state.stepPosition) * 0.05 * (0.5 + Double(state.wild))
            let wedge = 2 * Double.pi / Double(folds)
            let inner = unit * 0.14
            let spectrum = state.spectrum
            for fold in 0..<folds {
                let base = spin + Double(fold) * wedge
                let mirror = fold % 2 == 0 ? 1.0 : -1.0
                var path = Path()
                for band in 0..<bands {
                    let t = Double(band) / Double(bands - 1)
                    let angle = base + mirror * t * wedge * 0.5
                    let length = inner + unit * 0.7 * Double(spectrum[band])
                    let point = CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
                    band == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.stroke(
                    path,
                    with: .color(
                        color(Float(fold) / Float(folds) + state.beatPhase * 0.1, 0.55 + 0.4 * Double(state.energy))),
                    style: StrokeStyle(lineWidth: max(1.5, unit * 0.014), lineCap: .round, lineJoin: .round))
            }
        }
    }
#endif
