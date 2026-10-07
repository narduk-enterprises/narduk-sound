#if canImport(Metal)
    import Metal
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct AuroracurtainsShaderTests {
        static let size = (width: 96, height: 64)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer {
            try #require(
                ShaderPackRenderer(device: MTLCreateSystemDefaultDevice()),
                "the aurora shader did not compile or its pipeline could not be built")
        }

        static func state(bass: Float, mids: Float, highs: Float, kickOnLast: Bool = false, frames: Int = 90)
            -> SoundVisualState
        {
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
                    SoundVisualInput(frame: frame, music: Script.music(step: i / 4, kicks: kick)), now: now)
                now += 1.0 / 60
            }
            return state
        }

        static func render(
            _ state: SoundVisualState, calm: Bool = false, width: Int = size.width, height: Int = size.height
        ) throws -> [UInt8] {
            try #require(
                try renderer().renderOffscreen(.aurora, state: state, width: width, height: height, calm: calm))
        }

        static func mean(_ pixels: [UInt8], width: Int, y0: Int, y1: Int) -> Float {
            var sum: Float = 0
            var count: Float = 0
            for y in y0..<y1 {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    sum += (Float(pixels[i]) + Float(pixels[i + 1]) + Float(pixels[i + 2])) / (255 * 3)
                    count += 1
                }
            }
            return sum / count
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func bassLengthensTheCurtainsAndThePictureIsNeitherBlankNorWhite() throws {
            let quiet = try Self.render(Self.state(bass: 0.04, mids: 0.08, highs: 0.03))
            let loud = try Self.render(Self.state(bass: 0.95, mids: 0.08, highs: 0.03))
            #expect(quiet != loud)
            let width = Self.size.width
            let height = Self.size.height
            let quietBottom = Self.mean(quiet, width: width, y0: height * 3 / 5, y1: height)
            let loudBottom = Self.mean(loud, width: width, y0: height * 3 / 5, y1: height)
            #expect(
                loudBottom > quietBottom + 0.04,
                "bass did not bring the curtains down (\(quietBottom) vs \(loudBottom))")
            for (name, pixels) in [("quiet", quiet), ("loud", loud)] {
                let luma = Self.mean(pixels, width: width, y0: 0, y1: height)
                #expect(luma > 0.01, "\(name) drew nothing (mean \(luma))")
                #expect(luma < 0.85, "\(name) is a white flash (mean \(luma))")
            }
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSameStateRendersTheSamePicture() throws {
            let state = Self.state(bass: 0.55, mids: 0.4, highs: 0.2)
            #expect(try Self.render(state) == Self.render(state))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func calmStillDrawsAndDropsTheBeatGlow() throws {
            let state = Self.state(bass: 0.7, mids: 0.35, highs: 0.25, kickOnLast: true)
            let live = try Self.render(state, calm: false)
            let calm = try Self.render(state, calm: true)
            #expect(live != calm)
            let luma = Self.mean(calm, width: Self.size.width, y0: 0, y1: Self.size.height)
            #expect(luma > 0.01 && luma < 0.85, "calm mean \(luma)")
            #expect(state.kick > 0.5)
        }
    }
#endif
