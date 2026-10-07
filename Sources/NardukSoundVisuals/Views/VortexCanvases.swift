#if canImport(SwiftUI)
    import SwiftUI

    // Vortex: a spiral galaxy drawn from the spectrum. Three arms wind out from a hot core; each arm is the 64 bands in
    // order, bass at the core and highs at the rim, so the low end swells the middle and the top end sparkles the edge.
    // The waveform wraps the core as a jagged accretion ring, a snare throws a shock ring outward, a drop winds the
    // arms tighter and spins the field faster, and a starfield rotates differentially behind it all. Everything is a
    // function of the state: rotation comes from `travel`, twinkle from `time`, star positions from an integer hash.

    @MainActor extension SoundVisualizers {
        static let vortexArms = 3
        static let vortexStars = 96

        /// Deterministic noise in 0 ... 1 from an integer (a 64-bit mix, no table, no allocation).
        static func vortexHash(_ i: Int) -> Float {
            var x = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 29
            x = x &* 0xBF58_476D_1CE4_E5B9
            x ^= x >> 32
            return Float(x & 0xFF_FFFF) / Float(0x100_0000)
        }

        /// How tightly the arms wind: turns across one arm. A drop and an open wobble filter wind them tighter.
        static func vortexTwist(drop: Float, wobble: Float) -> Double {
            0.80 + 0.40 * Double(drop) + 0.18 * Double(wobble)
        }

        /// A band's distance from the core as a fraction of the galaxy radius: bass near the core, highs at the rim,
        /// pushed outward by the band's amplitude so a loud band bulges its arm.
        static func vortexBandRadius(_ band: Int, amplitude: Float) -> CGFloat {
            let t = CGFloat(band) / CGFloat(SoundVisualState.bandCount - 1)
            return 0.09 + 0.86 * pow(t, 0.72) + 0.07 * CGFloat(amplitude)
        }

        /// A band's angle on an arm (radians, clockwise on screen): the arm's base, the field's rotation and the spiral.
        static func vortexArmAngle(band: Int, arm: Int, rotation: Double, twist: Double) -> Double {
            let t = Double(band) / Double(SoundVisualState.bandCount - 1)
            let base = Double(arm) / Double(vortexArms) * 2 * .pi
            return base + rotation + twist * 2 * .pi * pow(t, 0.85)
        }

        /// Mean of a band range, folded without an array.
        static func vortexBandMean(_ spectrum: UnsafeBufferPointer<Float>, _ range: Range<Int>) -> Float {
            var sum: Float = 0
            for i in range { sum += spectrum[i] }
            return sum / Float(range.count)
        }

        static func vortex(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            background(&ctx, size, s, style, center: center)
            applyShake(&ctx, size, s)
            let m = min(size.width, size.height)
            // The galaxy reaches past the short edge so a wide card is filled corner to corner.
            let radius = max(size.width, size.height) * 0.42
            let motion: Double = s.calm ? 0.4 : 1
            let palette = s.palette
            let spectrum = s.spectrum
            let peaks = s.peaks
            let bass = vortexBandMean(spectrum, 0..<10)
            let mids = vortexBandMean(spectrum, 10..<36)
            let highs = vortexBandMean(spectrum, 36..<SoundVisualState.bandCount)
            let rotation = s.travel * motion * (2 * .pi / 12) + Double(s.beatPulse) * 0.03 * motion
            let twist = vortexTwist(drop: s.dropAmount, wobble: s.wobbleCutoff)

            // Stars: a differentially rotating field, inner stars faster, each twinkling on its own slow sine.
            var stars = Path()
            var brightStars = Path()
            for k in 0..<vortexStars {
                let h0 = vortexHash(k)
                let h1 = vortexHash(k + 1_000)
                let h2 = vortexHash(k + 2_000)
                let distance = 0.18 + 0.86 * CGFloat(h1)
                let angle = Double(h0) * 2 * .pi + rotation * (1.7 - Double(distance)) * 0.6
                let p = CGPoint(
                    x: center.x + cos(angle) * distance * radius, y: center.y + sin(angle) * distance * radius)
                let twinkle = 0.5 + 0.5 * sin(s.time * motion * (1.5 + 3 * Double(h2)) + Double(h0) * 6.283)
                let r = 0.7 + 1.1 * CGFloat(h2) + CGFloat(twinkle) * (0.6 + 1.6 * CGFloat(highs))
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                if twinkle > 0.72 { brightStars.addEllipse(in: rect) } else { stars.addEllipse(in: rect) }
            }
            var additive = ctx
            additive.blendMode = .plusLighter
            additive.fill(stars, with: .color(SoundCanvas.color(SoundCanvas.hot(palette.c2, 0.6), 0.45)))
            additive.fill(brightStars, with: .color(.white.opacity(0.55 + 0.3 * Double(highs))))

            // Arms: the spectrum wound into spirals, one bead per band, sized by its level and tiered by band range.
            var spines = Path()
            var bassBeads = Path()
            var midBeads = Path()
            var highBeads = Path()
            var peakTicks = Path()
            let count = SoundVisualState.bandCount
            for arm in 0..<vortexArms {
                for band in 0..<count {
                    let v = spectrum[band]
                    let a = vortexArmAngle(band: band, arm: arm, rotation: rotation, twist: twist)
                    let d = vortexBandRadius(band, amplitude: v) * radius
                    let p = CGPoint(x: center.x + CGFloat(cos(a)) * d, y: center.y + CGFloat(sin(a)) * d)
                    if band == 0 { spines.move(to: p) } else { spines.addLine(to: p) }
                    let level = CGFloat(pow(v, 0.8))
                    if band < 10 {
                        let r = 1.4 + level * m * 0.038 * (1 + 0.5 * CGFloat(s.kick))
                        bassBeads.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    } else if band < 36 {
                        let r = 1.2 + level * m * 0.03
                        midBeads.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    } else {
                        let r = 0.9 + level * m * 0.02 * (1 + CGFloat(s.laser))
                        highBeads.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    }
                    // Peak-hold ticks ride a little outside the arm, so the recent maximum stays visible.
                    let pk = CGFloat(pow(peaks[band], 0.8))
                    if pk > level + 0.08 {
                        let dp = vortexBandRadius(band, amplitude: peaks[band]) * radius + 3
                        let q = CGPoint(x: center.x + CGFloat(cos(a)) * dp, y: center.y + CGFloat(sin(a)) * dp)
                        peakTicks.move(to: q)
                        peakTicks.addLine(to: CGPoint(x: q.x + CGFloat(cos(a)) * 2, y: q.y + CGFloat(sin(a)) * 2))
                    }
                }
            }
            let armGradient = Gradient(colors: [
                SoundCanvas.color(palette.c0), SoundCanvas.color(palette.c1), SoundCanvas.color(palette.c2),
                SoundCanvas.color(palette.c0),
            ])
            let shading = GraphicsContext.Shading.conicGradient(armGradient, center: center, angle: .radians(rotation))
            let spineWidth = 1.5 + 1.8 * CGFloat(s.energy) + 1.2 * CGFloat(s.dropAmount)
            let spineStyle = StrokeStyle(lineWidth: spineWidth, lineCap: .round, lineJoin: .round)
            // Glitch: the arms split into the two optical fringes for the length of the envelope.
            if s.glitch > 0.05 {
                let shift = CGFloat(s.glitch) * 5
                var fringe = ctx
                fringe.blendMode = .plusLighter
                fringe.stroke(
                    spines.offsetBy(dx: -shift, dy: 0), with: .color(style.fringeA.opacity(0.55)), style: spineStyle)
                fringe.stroke(
                    spines.offsetBy(dx: shift, dy: 0), with: .color(style.fringeB.opacity(0.55)), style: spineStyle)
            }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 10))
                layer.stroke(spines, with: shading, style: StrokeStyle(lineWidth: spineWidth * 2.2))
            }
            ctx.stroke(spines, with: shading, style: spineStyle)
            additive.drawLayer { layer in
                layer.addFilter(.blur(radius: 6))
                layer.fill(bassBeads, with: .color(SoundCanvas.color(palette.c0, 0.55)))
            }
            additive.fill(bassBeads, with: .color(SoundCanvas.color(SoundCanvas.hot(palette.c0, 0.3), 0.8)))
            additive.fill(midBeads, with: .color(SoundCanvas.color(SoundCanvas.hot(palette.c1, 0.3), 0.9)))
            additive.fill(highBeads, with: .color(SoundCanvas.color(SoundCanvas.hot(palette.c2, 0.7))))
            ctx.stroke(
                peakTicks, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Shock ring: a snare throws one wave outward from the core; its envelope is the ring's age.
            if s.snare > 0.02 {
                let age = 1 - CGFloat(s.snare)
                let ring = soundCirclePath(center: center, radius: radius * (0.14 + 1.0 * age))
                ctx.stroke(
                    ring, with: .color(SoundCanvas.color(palette.c1, Double(s.snare) * 0.7)),
                    lineWidth: 1.5 + 5 * CGFloat(s.snare))
            }
            // Beat ring: a faint pulse leaves the core on every beat, so the tempo reads even between hits.
            let beatAge = CGFloat(s.beatPhase)
            ctx.stroke(
                soundCirclePath(center: center, radius: radius * (0.14 + 0.5 * beatAge)),
                with: .color(SoundCanvas.color(palette.c2, Double((1 - beatAge) * (1 - beatAge)) * 0.22)),
                lineWidth: 1.2)

            // Accretion ring: the waveform wrapped around the core, breathing with the bass and the kick.
            let coreRadius = m * (0.04 + 0.06 * CGFloat(bass) + 0.045 * CGFloat(s.kick))
            let ringRadius = coreRadius + m * 0.045
            let waveform = s.waveform
            var accretion = Path()
            let samples = SoundVisualState.sampleCount
            let step = 4
            for i in stride(from: 0, through: samples, by: step) {
                let w = CGFloat(waveform[i % samples])
                let a = Double(i) / Double(samples) * 2 * .pi + rotation * 0.5
                let r = ringRadius * (1 + 0.28 * w * (0.6 + CGFloat(mids)))
                let p = CGPoint(x: center.x + CGFloat(cos(a)) * r, y: center.y + CGFloat(sin(a)) * r)
                if i == 0 { accretion.move(to: p) } else { accretion.addLine(to: p) }
            }
            ctx.soundGlowStroke(
                accretion, color: SoundCanvas.color(palette.c2), width: 1.6 + 1.5 * CGFloat(s.kick),
                glow: 0.8, opacity: 0.6 + 0.4 * Double(s.level), hot: 0.5)

            // Core: a hot orb that breathes with the bass and jumps on the kick.
            ctx.soundGlowDot(
                center, radius: coreRadius, color: SoundCanvas.color(SoundCanvas.hot(palette.c0, 0.25)),
                intensity: 0.55 + 0.25 * Double(s.beatPulse))

            particles(&ctx, center: center, scale: m * 0.5, s, style)
            flash(&ctx, size, s)
        }
    }
#endif
