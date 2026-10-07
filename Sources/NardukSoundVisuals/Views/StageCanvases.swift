#if canImport(SwiftUI)
    import SwiftUI

    // The three stage Canvas visualizers lifted from Wirewatcher's `DropCanvasRenderers.swift`. Each draws from a
    // `SoundVisualState` and batches its geometry into a handful of paths, so a frame is a few fills, not hundreds. They
    // paint their own backdrop; the Metal tunnel is a separate renderer.

    @MainActor extension SoundVisualizers {
        // MARK: Shared

        static func background(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle,
            center: CGPoint
        ) {
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(style.stage))
            let glow = SoundCanvas.color(s.palette.c0, 0.08 + 0.16 * Double(s.energy) + 0.10 * Double(s.kick))
            let deep = SoundCanvas.color(s.palette.c1, 0.05 + 0.05 * Double(s.dropAmount))
            ctx.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [glow, deep, .clear]), center: center, startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.65))
        }

        static func applyShake(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState) {
            let m = min(size.width, size.height)
            ctx.translateBy(x: CGFloat(s.shakeOffset.x) * m, y: CGFloat(s.shakeOffset.y) * m)
        }

        /// The full-stage flash. Its rate limit (three a second at most) and its calm-mode silence live in the state.
        static func flash(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState) {
            guard s.flash > 0.01 else { return }
            ctx.fill(
                Path(CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)),
                with: .color(.white.opacity(Double(min(s.flash, 0.9)))))
        }

        static func particles(
            _ ctx: inout GraphicsContext, center: CGPoint, scale: CGFloat, _ s: SoundVisualState,
            _ style: SoundVisualizerStyle
        ) {
            var sparks = Path()
            var streaks = Path()
            let palette = s.palette
            for p in s.particles where p.life > 0 {
                let x = center.x + CGFloat(p.x) * scale
                let y = center.y + CGFloat(p.y) * scale
                let fade = CGFloat(1 - p.age)
                switch p.kind {
                case .spark:
                    let r = max(0.6, CGFloat(p.size) * fade * scale * 0.011)
                    sparks.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                case .streak:
                    streaks.move(to: CGPoint(x: x, y: y))
                    streaks.addLine(
                        to: CGPoint(
                            x: x - CGFloat(p.vx) * scale * 0.07 * fade, y: y - CGFloat(p.vy) * scale * 0.07 * fade))
                case .ring:
                    let radius = (0.28 + CGFloat(p.age) * 1.5) * scale
                    let ring = Path(
                        ellipseIn: CGRect(
                            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    ctx.stroke(
                        ring, with: .color(SoundCanvas.color(palette.c0, Double(fade * fade) * 0.7)),
                        lineWidth: 1.5 + 7 * fade)
                case .block:
                    let w = CGFloat(p.size) * scale
                    let h = max(3, w * 0.12)
                    let rect = CGRect(x: x, y: y, width: w, height: h)
                    let alpha = Double(fade) * 0.75
                    ctx.fill(Path(rect.offsetBy(dx: -6, dy: 0)), with: .color(style.fringeA.opacity(alpha)))
                    ctx.fill(Path(rect.offsetBy(dx: 6, dy: 0)), with: .color(style.fringeB.opacity(alpha)))
                    ctx.fill(Path(rect), with: .color(.white.opacity(alpha * 0.6)))
                }
            }
            ctx.fill(sparks, with: .color(SoundCanvas.color(palette.c1 * 0.5 + 0.5)))
            ctx.stroke(
                streaks, with: .color(SoundCanvas.color(palette.c2 * 0.6 + 0.4)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        private static func symmetricGradient(_ p: SoundPalette) -> Gradient {
            let a = SoundCanvas.color(p.c2)
            let b = SoundCanvas.color(p.c1)
            let c = SoundCanvas.color(p.c0)
            return Gradient(colors: [a, b, c, b, a])
        }

        // MARK: Mirror: symmetric log spectrum over a beat-scrolling neon floor

        /// A Mirror bar's width weight: bass bands widen in a drop.
        static func mirrorWeight(_ band: Int, _ drop: Float) -> CGFloat {
            let bass = max(0, 1 - CGFloat(band) / 12)
            return 1 + CGFloat(drop) * 1.6 * bass
        }

        static func mirror(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let w = size.width
            let h = size.height
            let horizon = h * 0.63
            let cx = w / 2
            background(&ctx, size, s, style, center: CGPoint(x: cx, y: horizon))
            applyShake(&ctx, size, s)
            let palette = s.palette

            // Floor: perspective grid whose rows roll toward the viewer once per beat.
            var grid = Path()
            let rows = 9
            let roll = CGFloat(s.travel - s.travel.rounded(.down))
            for k in 0..<rows {
                let u = (CGFloat(k) + roll) / CGFloat(rows)
                let y = horizon + (h - horizon) * u * u
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: w, y: y))
            }
            for k in -14...14 {
                grid.move(to: CGPoint(x: cx + CGFloat(k) * w * 0.018, y: horizon))
                grid.addLine(to: CGPoint(x: cx + CGFloat(k) * w * 0.16, y: h))
            }
            ctx.stroke(grid, with: .color(SoundCanvas.color(palette.c0, 0.16 + 0.22 * Double(s.kick))), lineWidth: 1)

            // Bars: bass at the center, highs out to both edges. The bass bands widen in a drop.
            let bandCount = SoundVisualState.bandCount
            var totalWeight: CGFloat = 0
            for i in 0..<bandCount { totalWeight += mirrorWeight(i, s.dropAmount) }
            let unit = (w * 0.94) / (totalWeight * 2)
            let maxHeight = horizon * 0.84
            let spectrum = s.spectrum
            let peaks = s.peaks
            var bars = Path()
            var caps = Path()
            var offset: CGFloat = 0
            for i in 0..<bandCount {
                let bw = mirrorWeight(i, s.dropAmount) * unit
                let gap = max(1, bw * 0.24)
                let barW = bw - gap
                let v = CGFloat(pow(spectrum[i], 0.85))
                let height = max(2, v * maxHeight)
                let peakY = horizon - CGFloat(pow(peaks[i], 0.85)) * maxHeight - 7
                let radius = min(barW / 2, 6)
                let right = cx + offset + gap / 2
                let left = cx - offset - bw + gap / 2
                bars.addRoundedRect(
                    in: CGRect(x: right, y: horizon - height, width: barW, height: height),
                    cornerSize: CGSize(width: radius, height: radius))
                bars.addRoundedRect(
                    in: CGRect(x: left, y: horizon - height, width: barW, height: height),
                    cornerSize: CGSize(width: radius, height: radius))
                caps.addRect(CGRect(x: right, y: peakY, width: barW, height: 3))
                caps.addRect(CGRect(x: left, y: peakY, width: barW, height: 3))
                offset += bw
            }

            let shading = GraphicsContext.Shading.linearGradient(
                symmetricGradient(palette), startPoint: CGPoint(x: cx - w * 0.47, y: 0),
                endPoint: CGPoint(x: cx + w * 0.47, y: 0))

            // Reflection on the floor.
            var reflection = ctx
            reflection.translateBy(x: 0, y: horizon * 2 + 6)
            reflection.scaleBy(x: 1, y: -1)
            reflection.opacity = 0.2
            reflection.fill(bars, with: shading)

            // Glow, body, then a top highlight for depth.
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 16))
                layer.opacity = 0.85 + 0.15 * Double(s.kick)
                layer.fill(bars, with: shading)
            }
            ctx.fill(bars, with: shading)
            ctx.fill(
                bars,
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.55), .white.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: horizon - maxHeight), endPoint: CGPoint(x: 0, y: horizon)))
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.fill(caps, with: .color(SoundCanvas.color(palette.c1 * 0.4 + 0.6)))
            }
            ctx.fill(caps, with: .color(.white.opacity(0.92)))

            // Horizon: a hot line that carries the live waveform.
            let waveform = s.waveform
            var scope = Path()
            let points = 256
            for i in 0..<points {
                let x = w * CGFloat(i) / CGFloat(points - 1)
                let y = horizon + CGFloat(waveform[i * 2]) * h * 0.035
                if i == 0 { scope.move(to: CGPoint(x: x, y: y)) } else { scope.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.stroke(scope, with: .color(SoundCanvas.color(palette.c1, 0.9)), lineWidth: 4)
            }
            ctx.stroke(scope, with: .color(.white.opacity(0.85)), lineWidth: 1.2)

            particles(&ctx, center: CGPoint(x: cx, y: horizon * 0.62), scale: min(w, h) * 0.5, s, style)
            flash(&ctx, size, s)
        }

        // MARK: Halo: radial spectrum around a pulsing core with an oscilloscope ring

        static func halo(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            background(&ctx, size, s, style, center: center)
            applyShake(&ctx, size, s)
            let m = min(size.width, size.height)
            let palette = s.palette
            let pulse = 1 + 0.12 * CGFloat(s.kick) + 0.03 * CGFloat(s.beatPulse)
            let core = m * 0.17 * pulse
            let inner = core + m * 0.025
            let maxLength = m * 0.27 * (1 + 0.25 * CGFloat(s.dropAmount))
            // One revolution per four bars, locked to the song position.
            let rotation = CGFloat(s.beats / 16 * 2 * .pi) - .pi / 2

            // Beat rings: one leaves the core every beat and fades over four beats.
            for k in 0..<4 {
                let age = (CGFloat(s.beatPhase) + CGFloat(k)) / 4
                let radius = inner + age * (maxLength * 1.5)
                let ring = Path(
                    ellipseIn: CGRect(
                        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ctx.stroke(
                    ring, with: .color(SoundCanvas.color(palette.c2, Double((1 - age) * (1 - age)) * 0.28)),
                    lineWidth: 1.2)
            }

            let spectrum = s.spectrum
            let peaks = s.peaks
            var bars = Path()
            var caps = Path()
            let count = SoundVisualState.bandCount
            let barWidth = max(1.5, 2 * .pi * inner / CGFloat(count * 2) * 0.58)
            for i in 0..<count {
                let v = CGFloat(pow(spectrum[i], 0.8))
                let length = max(2, v * maxLength)
                let peak = CGFloat(pow(peaks[i], 0.8)) * maxLength + 6
                let spread = (CGFloat(i) + 0.5) / CGFloat(count) * .pi
                for side in 0..<2 {
                    let angle = rotation + (side == 0 ? spread : -spread)
                    let dx = cos(angle)
                    let dy = sin(angle)
                    bars.move(to: CGPoint(x: center.x + dx * inner, y: center.y + dy * inner))
                    bars.addLine(to: CGPoint(x: center.x + dx * (inner + length), y: center.y + dy * (inner + length)))
                    caps.move(to: CGPoint(x: center.x + dx * (inner + peak), y: center.y + dy * (inner + peak)))
                    caps.addLine(
                        to: CGPoint(x: center.x + dx * (inner + peak + 2), y: center.y + dy * (inner + peak + 2)))
                }
            }
            let shading = GraphicsContext.Shading.conicGradient(
                symmetricGradient(palette), center: center, angle: .radians(Double(rotation) + .pi))
            let barStyle = StrokeStyle(lineWidth: barWidth, lineCap: .round)
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 14))
                layer.stroke(bars, with: shading, style: barStyle)
            }
            ctx.stroke(bars, with: shading, style: barStyle)
            ctx.stroke(caps, with: .color(.white.opacity(0.9)), style: barStyle)

            // Core: a hot orb that breathes with the kick.
            let coreRect = CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)
            ctx.fill(
                Path(ellipseIn: coreRect),
                with: .radialGradient(
                    Gradient(colors: [
                        .white.opacity(0.35 + 0.5 * Double(s.kick)),
                        SoundCanvas.color(palette.c1, 0.55 + 0.3 * Double(s.energy)),
                        SoundCanvas.color(palette.c0, 0.15),
                    ]), center: center, startRadius: 0, endRadius: core))

            // Oscilloscope ring: the waveform wrapped around the inside of the core.
            let waveform = s.waveform
            var scope = Path()
            let points = 256
            for i in 0...points {
                let t = CGFloat(i % points) / CGFloat(points)
                let angle = rotation + t * 2 * .pi
                let radius = core * 0.78 + CGFloat(waveform[(i % points) * 2]) * core * 0.32
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if i == 0 { scope.move(to: point) } else { scope.addLine(to: point) }
            }
            if s.chroma > 0.02 {
                let d = CGFloat(s.chroma) * 7
                ctx.stroke(scope.offsetBy(dx: -d, dy: 0), with: .color(style.fringeA.opacity(0.8)), lineWidth: 2)
                ctx.stroke(scope.offsetBy(dx: d, dy: 0), with: .color(style.fringeB.opacity(0.8)), lineWidth: 2)
            }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                layer.stroke(scope, with: .color(SoundCanvas.color(palette.c2, 0.9)), lineWidth: 4)
            }
            ctx.stroke(scope, with: .color(.white.opacity(0.95)), lineWidth: 1.4)

            particles(&ctx, center: center, scale: m * 0.5, s, style)
            flash(&ctx, size, s)
        }

        // MARK: Phosphor: X/Y Lissajous with persistence trails and the hit FX field

        static func phosphor(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(style.phosphorStage))
            ctx.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [SoundCanvas.color(s.palette.c0, 0.10 + 0.08 * Double(s.energy)), .clear]),
                    center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.6))
            applyShake(&ctx, size, s)
            let m = min(size.width, size.height)
            let palette = s.palette

            // CRT graticule.
            var graticule = Path()
            let cell = m * 0.1
            let columns = Int(size.width / cell / 2) + 1
            let rows = Int(size.height / cell / 2) + 1
            for k in -columns...columns {
                let x = center.x + CGFloat(k) * cell
                graticule.move(to: CGPoint(x: x, y: 0))
                graticule.addLine(to: CGPoint(x: x, y: size.height))
            }
            for k in -rows...rows {
                let y = center.y + CGFloat(k) * cell
                graticule.move(to: CGPoint(x: 0, y: y))
                graticule.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(graticule, with: .color(SoundCanvas.color(palette.c0, 0.07)), lineWidth: 1)
            var axes = Path()
            axes.move(to: CGPoint(x: center.x, y: 0))
            axes.addLine(to: CGPoint(x: center.x, y: size.height))
            axes.move(to: CGPoint(x: 0, y: center.y))
            axes.addLine(to: CGPoint(x: size.width, y: center.y))
            ctx.stroke(axes, with: .color(SoundCanvas.color(palette.c0, 0.16)), lineWidth: 1)

            // Trails oldest first; each is the waveform against itself a quarter-period later, rotated 45 degrees
            // like a stereo goniometer.
            let scale = m * 0.4 * (1 + 0.1 * CGFloat(s.kick))
            let depth = s.historyCount
            let sampleCount = SoundVisualState.sampleCount
            let history = s.history
            var newest = Path()
            var layer = ctx
            layer.blendMode = .plusLighter
            for age in stride(from: depth - 1, through: 0, by: -1) {
                let slot = (s.historyHead - age + SoundVisualState.historyDepth) % SoundVisualState.historyDepth
                let base = slot * sampleCount
                var trail = Path()
                var i = 0
                while i < sampleCount {
                    let a = CGFloat(history[base + i])
                    let b = CGFloat(history[base + (i + 32) % sampleCount])
                    let point = CGPoint(
                        x: center.x + (a - b) * 0.7071 * scale, y: center.y - (a + b) * 0.7071 * scale)
                    if i == 0 { trail.move(to: point) } else { trail.addLine(to: point) }
                    i += 2
                }
                if age == 0 {
                    newest = trail
                } else {
                    let fade = pow(0.68, Double(age))
                    layer.stroke(
                        trail, with: .color(SoundCanvas.color(palette.sample(Float(age) * 0.09), fade * 0.8)),
                        lineWidth: 1.2)
                }
            }
            ctx.drawLayer { glow in
                glow.addFilter(.blur(radius: 8))
                glow.stroke(newest, with: .color(SoundCanvas.color(palette.c1, 0.9)), lineWidth: 5)
            }
            ctx.stroke(newest, with: .color(SoundCanvas.color(palette.c1 * 0.3 + 0.7)), lineWidth: 1.6)

            particles(&ctx, center: center, scale: m * 0.5, s, style)

            // Scanlines for the CRT feel.
            var scan = Path()
            var y: CGFloat = 0
            while y < size.height {
                scan.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            ctx.fill(scan, with: .color(.black.opacity(0.18)))
            flash(&ctx, size, s)
        }
    }
#endif
