#if canImport(SwiftUI)
    import NardukSoundAnalysis
    import SwiftUI

    /// The kick-driven particle field: every kick throws a ring and a burst of sparks from the center, snares and
    /// hats add their own, and the whole field breathes with the energy. It draws the state's preallocated particle
    /// pool, so a busy song never grows memory, and everything flashy (bursts, streaks, blocks) is already gated by
    /// the state's calm mode.
    ///
    /// The view polls `input` from its own timeline at the frame budget in `\.soundFramesPerSecond` (docs/sound-contract.md
    /// sections 4 and 5) and advances `state` with `update`, which is idempotent per display frame, so the state can be
    /// shared with other visualizers.
    public struct ParticleFieldView: View {
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
                        ParticleField.draw(into: &context, size: size, state: state)
                    }
                }
            }
            .background(Color.black)
            .accessibilityHidden(true)
        }
    }

    /// The drawing half, separate so a golden test can render a fixed state.
    @MainActor public enum ParticleField {
        public static func draw(into context: inout GraphicsContext, size: CGSize, state: SoundVisualState) {
            let unit = Double(min(size.width, size.height)) / 2
            let center = CGPoint(
                x: size.width / 2 + Double(state.shakeOffset.x) * unit,
                y: size.height / 2 + Double(state.shakeOffset.y) * unit)
            let palette = state.palette
            func color(_ tint: Float, _ alpha: Double) -> Color {
                let c = palette.sample(tint - tint.rounded(.down))
                return Color(
                    .sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: max(0, min(1, alpha)))
            }

            // The core: a glow that swells on the kick and with the energy.
            let coreRadius = unit * Double(0.16 + 0.22 * state.kick + 0.1 * state.energy)
            let glow = Gradient(colors: [color(0.05, 0.85), color(0.4, 0.25), color(0.7, 0)])
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - coreRadius * 2.4, y: center.y - coreRadius * 2.4, width: coreRadius * 4.8,
                        height: coreRadius * 4.8)),
                with: .radialGradient(glow, center: center, startRadius: 0, endRadius: coreRadius * 2.4))

            context.blendMode = .plusLighter
            for particle in state.particles where particle.life > 0 {
                let age = Double(particle.age)
                let fade = 1 - age
                let at = CGPoint(x: center.x + Double(particle.x) * unit, y: center.y + Double(particle.y) * unit)
                switch particle.kind {
                case .ring:
                    let radius = unit * (0.15 + 1.05 * age)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(
                        Path(ellipseIn: rect), with: .color(color(particle.tint + 0.1, fade * 0.9)),
                        lineWidth: max(1, unit * 0.035 * fade))
                case .spark:
                    let r = unit * 0.014 * Double(particle.size) * (0.4 + fade)
                    context.fill(
                        Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2)),
                        with: .color(color(particle.tint, fade)))
                case .streak:
                    let tail = CGPoint(
                        x: at.x - Double(particle.vx) * unit * 0.06, y: at.y - Double(particle.vy) * unit * 0.06)
                    var path = Path()
                    path.move(to: tail)
                    path.addLine(to: at)
                    context.stroke(
                        path, with: .color(color(particle.tint, fade)),
                        style: StrokeStyle(lineWidth: max(1, unit * 0.01), lineCap: .round))
                case .block:
                    let w = unit * Double(particle.size)
                    context.fill(
                        Path(CGRect(x: at.x, y: at.y, width: w, height: w * 0.12)),
                        with: .color(color(particle.tint, fade * 0.6)))
                }
            }
        }
    }
#endif
