#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What the flowers react to. The shared `IntenseVisualizerTests` prove it compiles, draws, is deterministic,
    /// calms down and respects the flash cap; this file checks that the bass makes the blooms glow, that the highs
    /// sparkle them, that a kick flutters them (the picture moves) and that the beat opens them over time.
    @MainActor @Suite struct FlowerTests {
        static let size = (width: 128, height: 72)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func render(bass: Float, highs: Float, kicks: UInt32 = 0, frames: Int = 90) throws -> [UInt8] {
            let state = SoundVisualState(seed: 9)
            var limiter = IntenseFlashLimiter()
            var now = 2.0
            var spectrum = [Float](repeating: 0.03, count: SoundFrame.spectrumCount)
            for i in 0..<10 { spectrum[i] = bass }
            for i in 36..<SoundFrame.spectrumCount { spectrum[i] = highs }
            let wave = (0..<SoundFrame.waveformCount).map { Float(sin(Double($0) / 9)) * 0.5 }
            var counts = HitCounters()
            for frame in 0..<frames {
                if frame == frames - 1 { for _ in 0..<kicks { counts.record(.kick) } }
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
                    .flower, state: state, width: size.width, height: size.height, frames: 1, limiter: &limiter))
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            var sum = 0
            var i = 0
            while i < pixels.count {
                sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                i += 4
            }
            return Float(sum) / Float(pixels.count / 4 * 3 * 255)
        }

        static func drift(_ a: [UInt8], _ b: [UInt8]) -> Float {
            var sum = 0
            for i in 0..<a.count where i % 4 != 3 { sum += abs(Int(a[i]) - Int(b[i])) }
            return Float(sum) / Float(a.count / 4 * 3 * 255)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func theBassMakesTheBloomsGlow() throws {
            let quiet = try Self.render(bass: 0.03, highs: 0.1)
            let bassy = try Self.render(bass: 0.95, highs: 0.1)
            #expect(Self.mean(bassy) > Self.mean(quiet) + 0.005)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func theHighsSparkleThePollen() throws {
            let dull = try Self.render(bass: 0.3, highs: 0.0)
            let bright = try Self.render(bass: 0.3, highs: 0.95)
            #expect(Self.drift(dull, bright) > 0.001)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func aKickFluttersThePetals() throws {
            let plain = try Self.render(bass: 0.4, highs: 0.3)
            let kicked = try Self.render(bass: 0.4, highs: 0.3, kicks: 4)
            #expect(Self.drift(plain, kicked) > 0.002)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func theBeatOpensThem() throws {
            let now = try Self.render(bass: 0.4, highs: 0.3, frames: 90)
            let later = try Self.render(bass: 0.4, highs: 0.3, frames: 120)
            #expect(Self.drift(now, later) > 0.004)
        }
    }
#endif
