#if canImport(SwiftUI)
    import SwiftUI

    /// What a visualizer may choose that is not a series color: the stage backdrop, the dim label color and the two
    /// optical fringes of a chromatic split. Series colors always come from the state's palette.
    public struct SoundVisualizerStyle: Sendable {
        public var stage: Color
        public var phosphorStage: Color
        public var label: Color
        public var fringeA: Color
        public var fringeB: Color

        public init(
            stage: Color = Color(red: 0.012, green: 0.02, blue: 0.045),
            phosphorStage: Color = Color(red: 0.005, green: 0.012, blue: 0.02),
            label: Color = Color.white.opacity(0.55),
            fringeA: Color = Color(red: 1, green: 0.15, blue: 0.35),
            fringeB: Color = Color(red: 0.1, green: 0.85, blue: 1)
        ) {
            self.stage = stage
            self.phosphorStage = phosphorStage
            self.label = label
            self.fringeA = fringeA
            self.fringeB = fringeB
        }
    }

    extension SoundVisualizerStyle: Equatable {}

    extension SoundVisualizerStyle {
        /// This style with its fixed colors (stage backdrop, phosphor backdrop, the two chromatic fringes) derived from the
        /// state's palette while a look is active, so a color change reaches the backdrop too. The neutral look keeps the
        /// classic colors, so default goldens stay put.
        @MainActor func tinted(by state: SoundVisualState) -> SoundVisualizerStyle {
            if state.look.isNeutral { return self }
            let p = state.palette
            func dark(_ c: SIMD3<Float>, _ k: Float, _ floor: SIMD3<Float>) -> Color {
                let v = c * k + floor
                return Color(.sRGB, red: Double(v.x), green: Double(v.y), blue: Double(v.z), opacity: 1)
            }
            var out = self
            out.stage = dark(p.c0, 0.055, SIMD3(0.004, 0.006, 0.014))
            out.phosphorStage = dark(p.c1, 0.03, SIMD3(0.002, 0.005, 0.008))
            out.fringeA = SoundCanvas.color(p.c2)
            out.fringeB = SoundCanvas.color(p.c0)
            return out
        }
    }

    enum SoundCanvas {
        static func color(_ v: SIMD3<Float>, _ opacity: Double = 1) -> Color {
            Color(.sRGB, red: Double(v.x), green: Double(v.y), blue: Double(v.z), opacity: opacity)
        }

        /// A color halfway to white, for hot highlights.
        static func hot(_ v: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> {
            v * (1 - amount) + SIMD3<Float>(repeating: amount)
        }
    }

    extension GraphicsContext {
        /// A neon-tube stroke: a wide faint halo, a tighter glow, the colored line and a hot white core, all additive.
        func soundGlowStroke(
            _ path: Path, color: Color, width: CGFloat = 1.6, glow: CGFloat = 1, opacity: Double = 1,
            hot: Double = 0.4, cap: CGLineCap = .round
        ) {
            var c = self
            c.blendMode = .plusLighter
            func style(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: cap, lineJoin: .round) }
            if glow > 0 {
                c.stroke(path, with: .color(color.opacity(0.10 * opacity)), style: style(width + 9 * glow))
                c.stroke(path, with: .color(color.opacity(0.22 * opacity)), style: style(width + 4 * glow))
            }
            c.stroke(path, with: .color(color.opacity(opacity)), style: style(width))
            if hot > 0 {
                c.stroke(path, with: .color(Color.white.opacity(hot * opacity)), style: style(max(0.6, width * 0.4)))
            }
        }

        /// A glowing point: a radial halo with a white core.
        func soundGlowDot(_ point: CGPoint, radius: CGFloat, color: Color, intensity: Double = 1) {
            var c = self
            c.blendMode = .plusLighter
            let reach = radius * 5
            c.fill(
                Path(ellipseIn: CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.85 * intensity), color.opacity(0)]),
                    center: point, startRadius: 0, endRadius: reach))
            c.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Color.white.opacity(0.95 * intensity)))
        }
    }

    /// An arc as a polyline, so the angle direction never depends on Path's flipped-coordinate clockwise flag.
    /// Angles are radians, 0 = 3 o'clock, increasing clockwise on screen.
    func soundArcPath(center: CGPoint, radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, Int(abs(end - start) / 0.05))
        for k in 0...steps {
            let a = start + (end - start) * Double(k) / Double(steps)
            let p = CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    func soundCirclePath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
#endif
