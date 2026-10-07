#if canImport(Metal)
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// Bass blobs: the picture moves with the low bands, stays put for one state, and still draws in calm.
    @MainActor @Suite struct BassblobsShaderTests {
        static let size = (width: 96, height: 64)

        static func renderer() throws -> ShaderPackRenderer {
            let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device")
            if let renderer = ShaderPackRenderer(device: device) { return renderer }
            let options = MTLCompileOptions()
            options.mathMode = .fast
            // Surface the Metal log; the renderer swallows it.
            _ = try device.makeLibrary(source: ShaderPackSource.source, options: options)
            Issue.record("the shader compiled but the pipeline did not")
            fatalError("the shader compiled but the pipeline did not")
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            WobbleTunnelTests.grid(pixels, width: size.width, height: size.height, columns: 1, rows: 1).reduce(0, +)
                / 3
        }

        static func inRange(_ pixels: [UInt8]) -> Bool {
            let value = mean(pixels)
            return value > 0.01 && value < 0.85
        }

        /// A held spectrum so attack smoothing has settled. Two calls at the same clock differ only by the bands.
        static func state(
            bass: Float, mids: Float = 0.3, highs: Float = 0.08, kick: Bool = false, calm: Bool = false,
            frames: Int = 48, start: Double = 1.6
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 42)
            var now = start
            for i in 0..<frames {
                var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
                for band in 0..<10 { spectrum[band] = bass }
                for band in 10..<36 { spectrum[band] = mids }
                for band in 36..<SoundFrame.spectrumCount { spectrum[band] = highs }
                let waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
                let hits: UInt32 = kick && i == frames - 1 ? 1 : 0
                let frame = SoundFrame(
                    sequence: UInt64(i + 1), time: now, spectrum: spectrum, waveform: waveform, peakDB: -8,
                    rmsDB: -14)
                state.update(
                    SoundVisualInput(frame: frame, music: Script.music(step: i / 4, kicks: hits)), now: now,
                    options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func pixels(_ renderer: ShaderPackRenderer, _ state: SoundVisualState, calm: Bool = false) throws
            -> [UInt8]
        {
            try #require(
                renderer.renderOffscreen(
                    .bassBlobs, state: state, width: size.width, height: size.height, calm: calm))
        }

        @Test func bassChangesThePictureAndNeitherFrameIsBlankOrWhite() throws {
            let renderer = try Self.renderer()
            let quiet = try Self.pixels(renderer, Self.state(bass: 0.04))
            let loud = try Self.pixels(renderer, Self.state(bass: 0.95))
            #expect(quiet != loud)
            #expect(Self.inRange(quiet))
            #expect(Self.inRange(loud))
            let quietGrid = WobbleTunnelTests.grid(
                quiet, width: Self.size.width, height: Self.size.height, columns: 4, rows: 3)
            let loudGrid = WobbleTunnelTests.grid(
                loud, width: Self.size.width, height: Self.size.height, columns: 4, rows: 3)
            let delta = zip(quietGrid, loudGrid).map { abs($0 - $1) }.max() ?? 0
            #expect(delta > 0.05, "bass should move the picture, peak cell delta \(delta)")
        }

        @Test func midsChangeTheOrbitAndHighsRippleTheSurface() throws {
            let renderer = try Self.renderer()
            let slow = try Self.pixels(renderer, Self.state(bass: 0.45, mids: 0))
            let fast = try Self.pixels(renderer, Self.state(bass: 0.45, mids: 1))
            #expect(slow != fast)
            let smooth = try Self.pixels(renderer, Self.state(bass: 0.55, highs: 0))
            let rippled = try Self.pixels(renderer, Self.state(bass: 0.55, highs: 1))
            #expect(smooth != rippled)
        }

        @Test func theSameStateRendersTheSamePicture() throws {
            let renderer = try Self.renderer()
            let state = Self.state(bass: 0.7, mids: 0.4, highs: 0.35)
            #expect(try Self.pixels(renderer, state) == Self.pixels(renderer, state))
        }

        @Test func calmStillDrawsAndDropsTheKick() throws {
            let renderer = try Self.renderer()
            let calmState = Self.state(bass: 0.6, mids: 0.35, highs: 0.2, kick: true, calm: true)
            #expect(calmState.calm)
            #expect(calmState.flash == 0)
            let calm = try Self.pixels(renderer, calmState, calm: true)
            #expect(Self.inRange(calm))
            let kicked = Self.state(bass: 0.6, mids: 0.35, highs: 0.2, kick: true)
            let live = try Self.pixels(renderer, kicked, calm: false)
            let held = try Self.pixels(renderer, kicked, calm: true)
            #expect(Self.inRange(live))
            #expect(Self.inRange(held))
            #expect(live != held, "calm should remove the kick squash and slow the orbit")
        }
    }
#endif
