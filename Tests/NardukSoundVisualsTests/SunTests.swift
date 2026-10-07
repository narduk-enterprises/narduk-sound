#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What the sun reacts to. The shared `IntenseVisualizerTests` prove it compiles, draws, is deterministic, calms
    /// down and respects the flash cap; this file checks that the bass swells and heats the disc more than the highs
    /// do, that the highs still change the rim, and that a kick flares the surface.
    @MainActor @Suite struct SunTests {
        static let size = (width: 128, height: 72)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func render(bass: Float, highs: Float, kicks: UInt32 = 0, look: SoundPaletteLook = .neutral) throws
            -> [UInt8]
        {
            let state = SoundVisualState(seed: 9)
            state.look = look
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
                    .sun, state: state, width: size.width, height: size.height, frames: 1, limiter: &limiter))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theBassSwellsTheDiscMoreThanTheHighsDo() throws {
            let quiet = LiquidSplashTests.centerAndRim(try Self.render(bass: 0.03, highs: 0.03))
            let bassy = LiquidSplashTests.centerAndRim(try Self.render(bass: 0.95, highs: 0.03))
            let bright = LiquidSplashTests.centerAndRim(try Self.render(bass: 0.03, highs: 0.95))
            #expect(bassy.center > quiet.center + 0.02)
            #expect(bassy.center - quiet.center > bright.center - quiet.center)
            let brightPixels = try Self.render(bass: 0.03, highs: 0.95)
            let quietPixels = try Self.render(bass: 0.03, highs: 0.03)
            #expect(brightPixels != quietPixels)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aPaletteLookRecolorsTheStar() throws {
            let classic = try Self.render(bass: 0.4, highs: 0.3)
            var look = SoundPaletteLook.neutral
            look.hueShift = 0.5
            let shifted = try Self.render(bass: 0.4, highs: 0.3, look: look)
            #expect(classic != shifted)
            // The classic star is warm (red above blue at the center, BGRA bytes); a half-turn hue shift cools it.
            let mid = (Self.size.height / 2) * Self.size.width + Self.size.width / 2
            let warm = Int(classic[mid * 4 + 2]) - Int(classic[mid * 4])
            let cool = Int(shifted[mid * 4 + 2]) - Int(shifted[mid * 4])
            #expect(warm > cool)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aKickFlaresTheSurface() throws {
            let plain = try Self.render(bass: 0.4, highs: 0.3)
            let kicked = try Self.render(bass: 0.4, highs: 0.3, kicks: 4)
            #expect(plain != kicked)
            #expect(LiquidSplashTests.centerAndRim(kicked).center > LiquidSplashTests.centerAndRim(plain).center)
        }
    }
#endif
