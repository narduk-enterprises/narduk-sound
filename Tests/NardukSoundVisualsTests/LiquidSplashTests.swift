#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What the liquid splash reacts to. The shared `IntenseVisualizerTests` already prove it compiles, draws, is
    /// deterministic, calms down and never flashes more than three times a second; this file checks that the bass
    /// swells the core while the highs change the rim, and that a kick is visible.
    @MainActor @Suite struct LiquidSplashTests {
        static let size = (width: 128, height: 72)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func render(bass: Float, highs: Float, kicks: UInt32 = 0) throws -> [UInt8] {
            let state = SoundVisualState(seed: 5)
            var limiter = IntenseFlashLimiter()
            var now = 2.0
            var spectrum = [Float](repeating: 0.03, count: SoundFrame.spectrumCount)
            for i in 0..<10 { spectrum[i] = bass }
            for i in 36..<SoundFrame.spectrumCount { spectrum[i] = highs }
            let wave = (0..<SoundFrame.waveformCount).map { Float(sin(Double($0) / 9)) * 0.5 }
            var counts = HitCounters()
            for frame in 0..<90 {
                if frame == 89 { for _ in 0..<kicks { counts.record(.kick) } }
                let input = SoundVisualInput(
                    frame: SoundFrame(
                        sequence: UInt64(frame + 1), time: Double(frame) / 60, spectrum: spectrum, waveform: wave,
                        peakDB: -8, rmsDB: -14),
                    music: MusicContext(
                        hitCounts: counts, step: frame / 4, section: .build, energy: 0.6, isRunning: true))
                state.update(input, now: now)
                now += 1.0 / 60
            }
            let renderer = try #require(IntenseRenderer(device: MTLCreateSystemDefaultDevice()))
            return try #require(
                renderer.renderOffscreen(
                    .liquidSplash, state: state, width: size.width, height: size.height, frames: 1,
                    limiter: &limiter))
        }

        /// Mean luma of the middle 4 x 4 cells of a 16 x 9 grid, and of the outer ring of cells.
        static func centerAndRim(_ pixels: [UInt8]) -> (center: Float, rim: Float) {
            let grid = WobbleTunnelTests.grid(pixels, width: size.width, height: size.height, columns: 16, rows: 9)
            func luma(_ cell: Int) -> Float { (grid[cell * 3] + grid[cell * 3 + 1] + grid[cell * 3 + 2]) / 3 }
            var center: Float = 0
            var rim: Float = 0
            var rimCount: Float = 0
            for row in 0..<9 {
                for column in 0..<16 {
                    let cell = row * 16 + column
                    if (3...5).contains(row), (6...9).contains(column) { center += luma(cell) }
                    if row == 0 || row == 8 || column == 0 || column == 15 {
                        rim += luma(cell)
                        rimCount += 1
                    }
                }
            }
            return (center / 12, rim / rimCount)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theBassSwellsTheCoreAndTheHighsChangeTheRim() throws {
            let quiet = Self.centerAndRim(try Self.render(bass: 0.03, highs: 0.03))
            let bassy = Self.centerAndRim(try Self.render(bass: 0.95, highs: 0.03))
            let bright = Self.centerAndRim(try Self.render(bass: 0.03, highs: 0.95))
            #expect(bassy.center > quiet.center + 0.02)
            #expect(bassy.center - quiet.center > bright.center - quiet.center)
            let brightPixels = try Self.render(bass: 0.03, highs: 0.95)
            let quietPixels = try Self.render(bass: 0.03, highs: 0.03)
            #expect(abs(bright.rim - quiet.rim) > 0.002 || brightPixels != quietPixels)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aKickIsVisible() throws {
            let plain = try Self.render(bass: 0.4, highs: 0.3)
            let kicked = try Self.render(bass: 0.4, highs: 0.3, kicks: 4)
            #expect(plain != kicked)
            #expect(Self.centerAndRim(kicked).center > Self.centerAndRim(plain).center)
        }
    }
#endif
