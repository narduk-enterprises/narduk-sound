#if canImport(SwiftUI)
    import SwiftUI

    // Audio terrain: a neon wireframe landscape scrolling toward the viewer. The ground grid rolls with `travel`
    // (faster while `dropAmount` is up, at 0.4 in calm). Each waveform-history row is a ridge, newest nearest, so
    // the range flows away from the latest sound. Bass raises a wide central peak, mids the shoulders, highs a fine
    // jitter at the edges. `beatPulse` and `kick` lift the nearest ridge and its glow. c0 is the grid, c1 the
    // ridges, c2 the low sun and the horizon. There is no full-screen flash.

    @MainActor extension SoundVisualizers {
        static let terrainColumns = 36
        static let terrainSpokes = 13
        static let terrainRings = 8
        static let terrainNear: Double = 1.18
        static let terrainFar: Double = 10.5
        static let terrainCamera: Double = 1.02
        static let terrainHalfWidth: Double = 0.9
        static let terrainMinZ: Double = 0.4

        static func terrainMotion(calm: Bool) -> Double { calm ? 0.4 : 1 }

        /// Scroll position. Calm multiplies by 0.4; a drop speeds the roll.
        static func terrainScroll(travel: Double, drop: Float, calm: Bool) -> Double {
            let clamped = min(max(Double(drop), 0), 1)
            return travel * terrainMotion(calm: calm) * (1 + clamped * 1.5)
        }

        static func terrainPhase(_ scroll: Double) -> Double {
            let phase = scroll - scroll.rounded(.down)
            return phase >= 1 ? 0 : phase
        }

        /// Depth of row `index` (0 = nearest). Fractional `scroll` walks every row toward the camera.
        static func terrainDepth(index: Int, count: Int, scroll: Double) -> Double {
            let n = max(count, 1)
            let clamped = min(max(index, 0), n - 1)
            let u = (Double(clamped) + (1 - terrainPhase(scroll))) / Double(n)
            let inverse = (1 - u) / terrainNear + u / terrainFar
            return 1 / inverse
        }

        static func terrainHorizon(_ height: CGFloat) -> CGFloat { height * 0.40 }

        static func terrainFocalX(_ width: CGFloat) -> CGFloat { width * 0.55 }

        static func terrainFocalY(_ height: CGFloat) -> CGFloat { height * 0.62 }

        /// Perspective: x' = cx + x / z * f, y' = horizon + (camera - height) / z * f. Nil in front of the near plane.
        static func terrainProject(x: Double, height: Double, z: Double, size: CGSize) -> CGPoint? {
            guard z > terrainMinZ, size.width > 0, size.height > 0 else { return nil }
            let horizon = terrainHorizon(size.height)
            let sx = size.width * 0.5 + CGFloat(x / z) * terrainFocalX(size.width)
            let sy = horizon + CGFloat((terrainCamera - height) / z) * terrainFocalY(size.height)
            return CGPoint(x: sx, y: sy)
        }

        static func terrainU(column: Int, columns: Int) -> Float {
            guard columns > 1 else { return 0 }
            return Float(column) / Float(columns - 1) * 2 - 1
        }

        /// Deterministic 0 ... 1 noise from an integer, so a frame never calls a random source.
        static func terrainHash(_ index: Int) -> Float {
            var x = UInt32(truncatingIfNeeded: index)
            x &*= 0x9E37_79B9
            x ^= x >> 16
            x &*= 0x7FEB_352D
            x ^= x >> 15
            return Float(x & 0xFFFF) / 65_535
        }

        static func terrainBandEnergy(_ spectrum: UnsafeBufferPointer<Float>, from: Int, to: Int) -> Float {
            guard !spectrum.isEmpty else { return 0 }
            let lo = max(0, from)
            let hi = min(spectrum.count, to)
            guard hi > lo else { return 0 }
            var sum: Float = 0
            for index in lo..<hi { sum += spectrum[index] }
            return sum / Float(hi - lo)
        }

        /// Newest history at `age` 0 (`head`); older ages step backward around the ring.
        static func terrainHistorySlot(age: Int, head: Int, depth: Int) -> Int {
            guard depth > 0 else { return 0 }
            let wrapped = ((age % depth) + depth) % depth
            return (head - wrapped + depth * 2) % depth
        }

        static func terrainWaveSample(
            _ history: UnsafeBufferPointer<Float>, base: Int, sampleCount: Int, column: Int, columns: Int
        ) -> Float {
            guard sampleCount > 0, columns > 0, column >= 0, column < columns, base >= 0,
                base + sampleCount <= history.count
            else { return 0 }
            let start = min(sampleCount - 1, column * sampleCount / columns)
            let end = min(sampleCount, max(start + 1, (column + 1) * sampleCount / columns))
            var sum: Float = 0
            for index in start..<end { sum += history[base + index] }
            return sum / Float(end - start)
        }

        /// Ridge height. `u` is -1 ... 1 across the stage. `wave` is a history sample, -1 ... 1. `lift` is the
        /// beat/kick boost on the nearest row.
        static func terrainHeight(
            u: Float, bass: Float, mids: Float, highs: Float, wave: Float, jitter: Float, lift: Float
        ) -> Float {
            let centerFalloff: Float = 2.2
            let shoulderCenter: Float = 0.5
            let shoulderFalloff: Float = 16
            let edgeStart: Float = 0.62
            let au = abs(u)
            let center = exp(-u * u * centerFalloff)
            let shoulder = exp(-(au - shoulderCenter) * (au - shoulderCenter) * shoulderFalloff)
            let edge = max(0, (au - edgeStart) / (1 - edgeStart))
            let crest = max(wave, 0)
            let body: Float = 0.04 + 0.40 * crest
            let mountains = bass * center * 0.78 + mids * shoulder * 0.38
            let sparkle = highs * edge * (0.05 + 0.48 * abs(jitter))
            let beat = lift * (0.08 + 0.34 * center)
            return body + mountains + sparkle + beat
        }

        /// One sample of a history ridge, already placed in perspective. Age 0 is nearest and receives `lift`.
        static func terrainRidgePoint(
            age: Int, count: Int, column: Int, columns: Int, scroll: Double, bass: Float, mids: Float, highs: Float,
            lift: Float, history: UnsafeBufferPointer<Float>, head: Int, size: CGSize
        ) -> CGPoint? {
            guard count > 0, columns > 1, age >= 0, age < count, column >= 0, column < columns else { return nil }
            let sampleCount = SoundVisualState.sampleCount
            let slot = terrainHistorySlot(age: age, head: head, depth: SoundVisualState.historyDepth)
            let base = slot * sampleCount
            let u = terrainU(column: column, columns: columns)
            let wave = terrainWaveSample(
                history, base: base, sampleCount: sampleCount, column: column, columns: columns)
            let jitter = terrainHash(column &+ age &* 17) * 2 - 1
            var height = terrainHeight(
                u: u, bass: bass, mids: mids, highs: highs, wave: wave, jitter: jitter, lift: age == 0 ? lift : 0)
            let nearness = 1 - Float(age) / Float(max(count - 1, 1))
            height *= 0.62 + 0.38 * nearness
            let z = terrainDepth(index: age, count: count, scroll: scroll)
            return terrainProject(x: Double(u) * terrainHalfWidth, height: Double(height), z: z, size: size)
        }

        /// Lower sun stripes stay; the bottom of the disc loses every other band so the horizon shows through.
        static func terrainSunBandIncluded(_ band: Int, count: Int) -> Bool {
            guard band >= 0, count > 0, band < count else { return false }
            let along = (Float(band) + 0.5) / Float(count)
            if along > 0.5 { return band % 2 == 0 }
            return true
        }

        static func audioTerrain(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let width = size.width
            let height = size.height
            let horizon = terrainHorizon(height)
            let palette = s.palette
            let drop = min(max(s.dropAmount, 0), 1)
            let motion = terrainMotion(calm: s.calm)
            let scroll = terrainScroll(travel: s.travel, drop: drop, calm: s.calm)
            let pulse = Double(s.beatPulse) * motion
            let gridRGB = SoundCanvas.hot(palette.c0, 0.10 * drop)
            let ridgeRGB = SoundCanvas.hot(palette.c1, 0.20 * drop)
            let sunRGB = SoundCanvas.hot(palette.c2, 0.24 * drop)

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(style.stage))
            let sky = CGRect(x: 0, y: 0, width: width, height: max(horizon, 1))
            ctx.fill(
                Path(sky),
                with: .linearGradient(
                    Gradient(colors: [
                        style.stage,
                        SoundCanvas.color(palette.c2, 0.05 + 0.06 * Double(s.energy)),
                        SoundCanvas.color(sunRGB, 0.18 + 0.16 * Double(drop) + 0.06 * Double(s.energy)),
                    ]),
                    startPoint: CGPoint(x: width * 0.5, y: 0), endPoint: CGPoint(x: width * 0.5, y: horizon)))

            if let nearLeft = terrainProject(x: -terrainHalfWidth, height: 0, z: terrainNear, size: size),
                let nearRight = terrainProject(x: terrainHalfWidth, height: 0, z: terrainNear, size: size),
                let farLeft = terrainProject(x: -terrainHalfWidth, height: 0, z: terrainFar, size: size),
                let farRight = terrainProject(x: terrainHalfWidth, height: 0, z: terrainFar, size: size)
            {
                var ground = Path()
                ground.move(to: nearLeft)
                ground.addLine(to: nearRight)
                ground.addLine(to: farRight)
                ground.addLine(to: farLeft)
                ground.closeSubpath()
                ctx.fill(ground, with: .color(SoundCanvas.color(gridRGB, 0.05 + 0.04 * Double(drop))))
            }

            let glowCenter = CGPoint(x: width * 0.5, y: horizon)
            ctx.fill(
                Path(CGRect(x: 0, y: horizon - height * 0.2, width: width, height: height * 0.34)),
                with: .radialGradient(
                    Gradient(colors: [
                        SoundCanvas.color(sunRGB, 0.26 + 0.14 * Double(drop) + 0.08 * pulse), .clear,
                    ]),
                    center: glowCenter, startRadius: 0, endRadius: width * 0.4))

            var horizonLine = Path()
            horizonLine.move(to: CGPoint(x: 0, y: horizon))
            horizonLine.addLine(to: CGPoint(x: width, y: horizon))
            ctx.soundGlowStroke(
                horizonLine, color: SoundCanvas.color(sunRGB), width: 1.6,
                glow: 0.65 + 0.5 * CGFloat(pulse), opacity: 0.42, hot: 0.1)

            let sunRadius = min(width, height) * 0.145
            terrainSun(
                &ctx, center: CGPoint(x: width * 0.5, y: horizon - sunRadius * 0.12), radius: sunRadius,
                color: SoundCanvas.color(sunRGB, 0.92))

            var spokes = Path()
            for spoke in 0..<terrainSpokes {
                let x = -terrainHalfWidth + (2 * terrainHalfWidth) * Double(spoke) / Double(terrainSpokes - 1)
                guard let far = terrainProject(x: x, height: 0, z: terrainFar, size: size),
                    let near = terrainProject(x: x, height: 0, z: terrainNear, size: size)
                else { continue }
                spokes.move(to: far)
                spokes.addLine(to: near)
            }
            let spokeAlpha = 0.28 + 0.16 * pulse + 0.1 * Double(drop)
            ctx.stroke(spokes, with: .color(SoundCanvas.color(gridRGB, spokeAlpha * 0.45)), lineWidth: 4)
            ctx.stroke(spokes, with: .color(SoundCanvas.color(gridRGB, spokeAlpha)), lineWidth: 1.5)

            for ring in 0..<terrainRings {
                let z = terrainDepth(index: ring, count: terrainRings, scroll: scroll)
                guard let left = terrainProject(x: -terrainHalfWidth, height: 0, z: z, size: size),
                    let right = terrainProject(x: terrainHalfWidth, height: 0, z: z, size: size)
                else { continue }
                var line = Path()
                line.move(to: left)
                line.addLine(to: right)
                let away = Double(ring) / Double(max(terrainRings - 1, 1))
                let alpha = (0.62 + 0.2 * pulse) * (1 - 0.7 * away)
                ctx.stroke(line, with: .color(SoundCanvas.color(gridRGB, alpha)), lineWidth: 1.5)
            }

            guard s.historyCount > 0 else { return }
            let bass = terrainBandEnergy(s.spectrum, from: 0, to: 10)
            let mids = terrainBandEnergy(s.spectrum, from: 10, to: 36)
            let highs = terrainBandEnergy(s.spectrum, from: 36, to: SoundVisualState.bandCount)
            let lift = (s.kick * 0.7 + s.beatPulse * 0.45) * Float(motion)
            var farCrest = Path()
            var midCrest = Path()
            var nearCrest = Path()
            var ribs = Path()
            let history = s.history
            let count = s.historyCount
            for age in stride(from: count - 1, through: 0, by: -1) {
                if age == 0 {
                    addTerrainRidge(
                        &nearCrest, &ribs, age: age, count: count, scroll: scroll, bass: bass, mids: mids,
                        highs: highs, lift: lift, history: history, head: s.historyHead, size: size)
                } else if age < 3 {
                    addTerrainRidge(
                        &midCrest, &ribs, age: age, count: count, scroll: scroll, bass: bass, mids: mids,
                        highs: highs, lift: lift, history: history, head: s.historyHead, size: size)
                } else {
                    addTerrainRidge(
                        &farCrest, &ribs, age: age, count: count, scroll: scroll, bass: bass, mids: mids,
                        highs: highs, lift: lift, history: history, head: s.historyHead, size: size)
                }
            }
            ctx.stroke(ribs, with: .color(SoundCanvas.color(ridgeRGB, 0.2 + 0.08 * Double(drop))), lineWidth: 1.5)
            ctx.stroke(
                farCrest, with: .color(SoundCanvas.color(ridgeRGB, 0.36 + 0.1 * Double(drop))), lineWidth: 1.5)
            ctx.stroke(
                midCrest, with: .color(SoundCanvas.color(ridgeRGB, 0.62 + 0.12 * Double(drop))), lineWidth: 1.8)
            let kick = CGFloat(s.kick) * CGFloat(motion)
            ctx.soundGlowStroke(
                nearCrest, color: SoundCanvas.color(ridgeRGB), width: 2.3 + 1.15 * kick + 0.55 * CGFloat(pulse),
                glow: 0.8 + 0.95 * kick + 0.65 * CGFloat(pulse), opacity: 0.9, hot: 0.16 + 0.1 * Double(kick))
        }

        private static func addTerrainRidge(
            _ crest: inout Path, _ ribs: inout Path, age: Int, count: Int, scroll: Double, bass: Float, mids: Float,
            highs: Float, lift: Float, history: UnsafeBufferPointer<Float>, head: Int, size: CGSize
        ) {
            let columns = terrainColumns
            var started = false
            for column in 0..<columns {
                guard
                    let point = terrainRidgePoint(
                        age: age, count: count, column: column, columns: columns, scroll: scroll, bass: bass,
                        mids: mids, highs: highs, lift: lift, history: history, head: head, size: size)
                else { continue }
                if started {
                    crest.addLine(to: point)
                } else {
                    crest.move(to: point)
                    started = true
                }
                if column % 4 == 0, age + 1 < count,
                    let further = terrainRidgePoint(
                        age: age + 1, count: count, column: column, columns: columns, scroll: scroll, bass: bass,
                        mids: mids, highs: highs, lift: lift, history: history, head: head, size: size)
                {
                    ribs.move(to: point)
                    ribs.addLine(to: further)
                }
            }
        }

        private static func terrainSun(
            _ ctx: inout GraphicsContext, center: CGPoint, radius: CGFloat, color: Color
        ) {
            let count = 8
            let bandHeight = radius * 2 / CGFloat(count)
            var bands = Path()
            for band in 0..<count where terrainSunBandIncluded(band, count: count) {
                let y = center.y - radius + CGFloat(band) * bandHeight
                let mid = y + bandHeight * 0.5 - center.y
                let inside = radius * radius - mid * mid
                guard inside > 0 else { continue }
                let half = inside.squareRoot()
                let stripe = max(1.5, bandHeight * 0.72)
                bands.addRect(
                    CGRect(
                        x: center.x - half, y: y + (bandHeight - stripe) / 2, width: half * 2, height: stripe))
            }
            ctx.fill(bands, with: .color(color))
        }
    }
#endif
