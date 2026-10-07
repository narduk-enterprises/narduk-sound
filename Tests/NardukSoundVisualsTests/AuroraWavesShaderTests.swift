#if canImport(Metal)
    import Foundation
    import Metal
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    #if canImport(ImageIO) && canImport(CoreGraphics)
        import CoreGraphics
        import ImageIO
    #endif

    @MainActor @Suite struct AuroraWavesShaderTests {
        static let size = (width: 160, height: 90)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer {
            try #require(
                ShaderPackRenderer(device: MTLCreateSystemDefaultDevice()),
                "the aurora waves shader did not compile or its pipeline could not be built")
        }

        /// A state built from a flat spectrum per tier (bass 0-9, mids 10-35, highs 36-63), advanced `frames` frames
        /// in the drop, with an optional kick on the last frame.
        static func state(
            bass: Float, mids: Float, highs: Float, kickOnLast: Bool = false, frames: Int = 90, calm: Bool = false
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 42)
            var now = 1.0
            for i in 0..<frames {
                var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
                for band in 0..<10 { spectrum[band] = bass }
                for band in 10..<36 { spectrum[band] = mids }
                for band in 36..<SoundFrame.spectrumCount { spectrum[band] = highs }
                var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
                let level = max(bass, max(mids, highs))
                for sample in 0..<waveform.count { waveform[sample] = sin(Float(sample) / 20) * level }
                let audible = level > 0.01
                let kick: UInt32 = kickOnLast && i == frames - 1 ? 1 : 0
                let frame = SoundFrame(
                    sequence: UInt64(i + 1), time: Double(i) / 60, spectrum: spectrum, waveform: waveform,
                    peakDB: audible ? -12 : -120, rmsDB: audible ? -18 : -120)
                state.update(
                    SoundVisualInput(frame: frame, music: Script.music(step: i / 4, kicks: kick)), now: now,
                    options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func render(
            _ state: SoundVisualState, calm: Bool = false, width: Int = size.width, height: Int = size.height
        ) throws -> [UInt8] {
            try #require(
                try renderer().renderOffscreen(.auroraWaves, state: state, width: width, height: height, calm: calm))
        }

        /// Mean luminance (r+g+b)/3 of rows y0..<y1 (top-down), 0 ... 1.
        static func mean(_ pixels: [UInt8], width: Int = size.width, y0: Int, y1: Int) -> Float {
            var sum: Float = 0
            for y in y0..<y1 {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    sum += Float(pixels[i]) + Float(pixels[i + 1]) + Float(pixels[i + 2])
                }
            }
            return sum / Float((y1 - y0) * width * 3 * 255)
        }

        /// Mean absolute per-channel difference of two pictures in rows y0..<y1, 0 ... 1.
        static func drift(_ a: [UInt8], _ b: [UInt8], width: Int = size.width, y0: Int, y1: Int) -> Float {
            var sum: Float = 0
            for i in (y0 * width * 4)..<(y1 * width * 4) where i % 4 != 3 {
                sum += abs(Float(a[i]) - Float(b[i]))
            }
            return sum / Float((y1 - y0) * width * 3 * 255)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func quietAndLoudBothDrawANightSkyThatIsNeitherBlankNorWhite() throws {
            for state in [Self.state(bass: 0, mids: 0, highs: 0), Self.state(bass: 0.9, mids: 0.6, highs: 0.4)] {
                let pixels = try Self.render(state)
                let whole = Self.mean(pixels, y0: 0, y1: Self.size.height)
                #expect(whole > 0.04, "blank (mean \(whole))")
                #expect(whole < 0.6, "too bright (mean \(whole))")
                // The ribbons in the middle third are brighter than the sky at the top.
                let top = Self.mean(pixels, y0: 0, y1: Self.size.height / 8)
                let middle = Self.mean(pixels, y0: Self.size.height * 3 / 10, y1: Self.size.height * 6 / 10)
                #expect(middle > top + 0.03, "no ribbons (middle \(middle), top \(top))")
            }
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func theSameStateRendersTheSamePicture() throws {
            let state = Self.state(bass: 0.7, mids: 0.5, highs: 0.3)
            #expect(try Self.render(state) == Self.render(state))
        }

        /// Bass swells the ribbons: the middle band changes a lot more than the top sky does.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func bassSwellsTheRibbons() throws {
            let quiet = try Self.render(Self.state(bass: 0.05, mids: 0.2, highs: 0.1))
            let loud = try Self.render(Self.state(bass: 0.95, mids: 0.2, highs: 0.1))
            let h = Self.size.height
            let ribbons = Self.drift(quiet, loud, y0: h * 2 / 10, y1: h * 7 / 10)
            let sky = Self.drift(quiet, loud, y0: 0, y1: h / 10)
            #expect(ribbons > 0.03, "bass did not move the ribbons (\(ribbons))")
            #expect(ribbons > sky * 3, "bass moved the sky as much as the ribbons (\(ribbons) vs \(sky))")
            // Thicker ribbons carry more light.
            #expect(Self.mean(loud, y0: h * 2 / 10, y1: h * 7 / 10) > Self.mean(quiet, y0: h * 2 / 10, y1: h * 7 / 10))
        }

        /// The highs raise the embedded equaliser bars and twinkle the stars; the change is fine detail, smaller
        /// than what the bass does.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func highsRaiseTheBarsLessThanBassMovesRibbons()
            throws
        {
            let h = Self.size.height
            let base = try Self.render(Self.state(bass: 0.1, mids: 0.2, highs: 0.0))
            let highs = try Self.render(Self.state(bass: 0.1, mids: 0.2, highs: 0.9))
            let bass = try Self.render(Self.state(bass: 0.9, mids: 0.2, highs: 0.0))
            let fromHighs = Self.drift(base, highs, y0: 0, y1: h)
            let fromBass = Self.drift(base, bass, y0: 0, y1: h)
            #expect(fromHighs > 0.002, "the highs changed nothing (\(fromHighs))")
            #expect(fromBass > fromHighs, "bass \(fromBass) should outweigh highs \(fromHighs)")
        }

        /// A kick swells only the ribbon cores: visible, but bounded well under a flash, and gone in calm.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func aKickIsABoundedGlowAndCalmDropsIt() throws {
            let h = Self.size.height
            let plain = Self.state(bass: 0.6, mids: 0.4, highs: 0.2)
            let kicked = Self.state(bass: 0.6, mids: 0.4, highs: 0.2, kickOnLast: true)
            let without = try Self.render(plain)
            let with = try Self.render(kicked)
            let swell = Self.mean(with, y0: 0, y1: h) - Self.mean(without, y0: 0, y1: h)
            #expect(swell > 0.002, "the kick is invisible (\(swell))")
            #expect(swell < 0.08, "the kick is a flash (\(swell))")
            // Calm: the same kick changes nothing that the calm picture shows.
            let calmWithout = try Self.render(plain, calm: true)
            let calmWith = try Self.render(kicked, calm: true)
            #expect(Self.drift(calmWithout, calmWith, y0: 0, y1: h) < 0.001)
            // Calm still draws the picture.
            #expect(Self.mean(calmWith, y0: 0, y1: h) > 0.04)
        }

        /// No strobe: over four seconds of a kick-every-quarter-second drop at 60 fps the mean luma never jumps by
        /// more than 0.1 of full scale between frames, so there are no flashes at all, far under three a second.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func aBusyDropNeverFlashes() throws {
            let renderer = try Self.renderer()
            let state = SoundVisualState(seed: 7)
            var now = 1.0
            var previous: Float?
            var worstJump: Float = 0
            for i in 0..<240 {
                let kicks: UInt32 = i % 15 == 0 ? 1 : 0
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(i + 1), level: 0.8),
                    music: Script.music(step: i / 4, kicks: kicks, snares: i % 30 == 15 ? 1 : 0))
                state.update(input, now: now)
                now += 1.0 / 60
                let pixels = try #require(
                    renderer.renderOffscreen(.auroraWaves, state: state, width: 48, height: 27))
                let luma = Self.mean(pixels, width: 48, y0: 0, y1: 27)
                if let previous { worstJump = max(worstJump, luma - previous) }
                previous = luma
            }
            #expect(worstJump < 0.1, "a frame-to-frame jump of \(worstJump) is a flash")
        }

        /// The waves never sit still: with the same steady music, a quarter of a second later the ribbons have moved
        /// visibly, and two seconds later they have changed shape, not just drifted a little further.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func theRibbonsKeepFlowing() throws {
            let h = Self.size.height
            let now = try Self.render(Self.state(bass: 0.4, mids: 0.3, highs: 0.2, frames: 90))
            let soon = try Self.render(Self.state(bass: 0.4, mids: 0.3, highs: 0.2, frames: 105))
            let later = try Self.render(Self.state(bass: 0.4, mids: 0.3, highs: 0.2, frames: 210))
            let quarter = Self.drift(now, soon, y0: h * 2 / 10, y1: h * 7 / 10)
            let twoSeconds = Self.drift(now, later, y0: h * 2 / 10, y1: h * 7 / 10)
            #expect(quarter > 0.015, "the ribbons barely moved in a quarter second (\(quarter))")
            #expect(twoSeconds > quarter, "two seconds on looks like a quarter second on (\(twoSeconds))")
        }

        /// Jumpy, not just bright: a kick moves the ribbons themselves (their light lands somewhere else), far more
        /// than its bounded glow changes the mean.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func aKickPunchesTheRibbons() throws {
            let h = Self.size.height
            let without = try Self.render(Self.state(bass: 0.6, mids: 0.4, highs: 0.2))
            let with = try Self.render(Self.state(bass: 0.6, mids: 0.4, highs: 0.2, kickOnLast: true))
            let moved = Self.drift(without, with, y0: h * 2 / 10, y1: h * 7 / 10)
            let glow = abs(Self.mean(with, y0: 0, y1: h) - Self.mean(without, y0: 0, y1: h))
            #expect(moved > 0.03, "the kick did not move the ribbons (\(moved))")
            #expect(moved > glow * 2, "the kick only brightened (moved \(moved), glow \(glow))")
        }

        /// Writes a filmstrip (frames a quarter second apart) when `NARDUK_AURORA_WAVES_DUMP` names a directory.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func writesAFilmstripWhenAskedTo() throws {
            #if canImport(ImageIO) && canImport(CoreGraphics)
                guard let directory = ProcessInfo.processInfo.environment["NARDUK_AURORA_WAVES_DUMP"] else { return }
                for step in 0..<6 {
                    let state = Self.state(bass: 0.6, mids: 0.4, highs: 0.3, frames: 90 + step * 15)
                    let pixels = try Self.render(state, width: 640, height: 360)
                    try Self.writePNG(pixels, width: 640, height: 360, to: "\(directory)/aurora-waves-film-\(step).png")
                }
                // A real drop, a kick every quarter second: frames 0, 3, 6 and 12 after a kick.
                let renderer = try Self.renderer()
                let state = SoundVisualState(seed: 7)
                var now = 1.0
                for i in 0..<133 {
                    let input = SoundVisualInput(
                        frame: Script.frame(UInt64(i + 1), level: 0.8),
                        music: Script.music(step: i / 4, kicks: i % 15 == 0 ? 1 : 0, snares: i % 30 == 15 ? 1 : 0))
                    state.update(input, now: now)
                    now += 1.0 / 60
                    guard [120, 123, 126, 132].contains(i) else { continue }
                    let pixels = try #require(
                        renderer.renderOffscreen(.auroraWaves, state: state, width: 640, height: 360))
                    try Self.writePNG(
                        pixels, width: 640, height: 360, to: "\(directory)/aurora-waves-kick-\(i - 120).png")
                }
            #endif
        }

        /// Writes full-size quiet and loud stills when `NARDUK_AURORA_WAVES_DUMP` names a directory (for review).
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func writesStillsWhenAskedTo() throws {
            #if canImport(ImageIO) && canImport(CoreGraphics)
                guard let directory = ProcessInfo.processInfo.environment["NARDUK_AURORA_WAVES_DUMP"] else { return }
                let stills: [(String, SoundVisualState, Bool, Int, Int)] = [
                    ("quiet", Self.state(bass: 0.12, mids: 0.1, highs: 0.06), false, 1280, 720),
                    ("loud", Self.state(bass: 0.95, mids: 0.6, highs: 0.45, kickOnLast: true), false, 1280, 720),
                    ("busy", WobbleTunnelTests.busyState(), false, 1280, 720),
                    ("calm", Self.state(bass: 0.6, mids: 0.4, highs: 0.2, calm: true), true, 1280, 720),
                    ("card", WobbleTunnelTests.busyState(), false, 480, 270),
                    ("portrait", WobbleTunnelTests.busyState(), false, 393, 852),
                ]
                for (name, state, calm, width, height) in stills {
                    let pixels = try Self.render(state, calm: calm, width: width, height: height)
                    try Self.writePNG(pixels, width: width, height: height, to: "\(directory)/aurora-waves-\(name).png")
                }
            #endif
        }

        #if canImport(ImageIO) && canImport(CoreGraphics)
            static func writePNG(_ bgra: [UInt8], width: Int, height: Int, to path: String) throws {
                var rgba = bgra
                for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
                let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
                let image = try #require(
                    CGImage(
                        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let url = URL(fileURLWithPath: path) as CFURL
                let destination = try #require(CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        #endif
    }
#endif
