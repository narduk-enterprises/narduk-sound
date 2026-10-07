#if canImport(Metal)
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct OceanwavesShaderTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil
        static let size = (width: 96, height: 64)

        static func renderer() throws -> ShaderPackRenderer {
            try #require(
                ShaderPackRenderer(device: MTLCreateSystemDefaultDevice()),
                "a pack shader did not compile or its pipeline could not be built")
        }

        static func frame(_ sequence: UInt64, bass: Float, mids: Float, highs: Float, loud: Bool) -> SoundFrame {
            var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
            for index in 0..<10 { spectrum[index] = bass }
            for index in 10..<36 { spectrum[index] = mids }
            for index in 36..<SoundFrame.spectrumCount { spectrum[index] = highs }
            var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
            for index in 0..<waveform.count {
                waveform[index] = sin(Float(index) * 0.07) * (0.15 + 0.5 * bass)
            }
            let rms: Float = loud ? -12 : -72
            return SoundFrame(
                sequence: sequence, time: Double(sequence) / 60, spectrum: spectrum, waveform: waveform,
                peakDB: rms + 6, rmsDB: rms)
        }

        /// Same clock and energy for both pictures, so a bass change is the swell, not a different moment.
        static func state(
            bass: Float, mids: Float, highs: Float, kick: Bool, drop: Bool, calm: Bool, frames: Int = 48
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 7)
            var now = 1.0
            for index in 0..<frames {
                var counts = HitCounters()
                if kick, index == frames - 1 { counts.record(.kick) }
                let input = SoundVisualInput(
                    frame: frame(UInt64(index + 1), bass: bass, mids: mids, highs: highs, loud: bass > 0.2),
                    music: MusicContext(
                        hitCounts: counts, step: index / 4, section: drop ? .drop : .intro, energy: 0.45,
                        isRunning: true))
                state.update(input, now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func render(_ state: SoundVisualState, calm: Bool = false) throws -> [UInt8] {
            try #require(
                try renderer().renderOffscreen(
                    .oceanWaves, state: state, width: size.width, height: size.height, calm: calm))
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            var sum: Float = 0
            var count: Float = 0
            var index = 0
            while index + 3 < pixels.count {
                let red = Float(pixels[index + 2])
                let green = Float(pixels[index + 1])
                let blue = Float(pixels[index])
                sum += (red + green + blue) / (255 * 3)
                count += 1
                index += 4
            }
            return sum / max(count, 1)
        }

        static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Float {
            var sum: Float = 0
            var samples: Float = 0
            var index = 0
            let count = min(a.count, b.count)
            while index + 3 < count {
                sum += abs(Float(a[index]) - Float(b[index]))
                sum += abs(Float(a[index + 1]) - Float(b[index + 1]))
                sum += abs(Float(a[index + 2]) - Float(b[index + 2]))
                samples += 3
                index += 4
            }
            return sum / max(samples, 1) / 255
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func bassChangesThePicture() throws {
            let quiet = Self.state(bass: 0.04, mids: 0.08, highs: 0.05, kick: false, drop: false, calm: false)
            let loud = Self.state(bass: 1, mids: 0.08, highs: 0.05, kick: false, drop: false, calm: false)
            let quietPixels = try Self.render(quiet)
            let loudPixels = try Self.render(loud)
            #expect(quietPixels != loudPixels)
            let delta = Self.meanAbsoluteDifference(quietPixels, loudPixels)
            #expect(delta > 0.02, "bass did not move the sea (mean abs \(delta))")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSameStateRendersTheSamePicture() throws {
            let state = Self.state(bass: 0.7, mids: 0.5, highs: 0.4, kick: true, drop: true, calm: false)
            #expect(try Self.render(state) == Self.render(state))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func calmIsAPictureWithoutTheKickSwell() throws {
            let kicked = Self.state(bass: 0.8, mids: 0.4, highs: 0.3, kick: true, drop: false, calm: false)
            let live = try Self.render(kicked, calm: false)
            let calm = try Self.render(kicked, calm: true)
            let calmMean = Self.mean(calm)
            #expect(calmMean > 0.02, "calm drew nothing (\(calmMean))")
            #expect(calmMean < 0.85, "calm is a white flash (\(calmMean))")
            #expect(live != calm)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aQuietSeaAndALoudDropAreNeitherBlankNorWhite() throws {
            let quiet = Self.state(bass: 0.02, mids: 0.04, highs: 0.02, kick: false, drop: false, calm: false)
            let loud = Self.state(bass: 1, mids: 0.8, highs: 0.7, kick: true, drop: true, calm: false)
            for pixels in [try Self.render(quiet), try Self.render(loud)] {
                let value = Self.mean(pixels)
                #expect(value > 0.02, "ocean drew nothing (\(value))")
                #expect(value < 0.85, "ocean is a white flash (\(value))")
            }
        }
    }
#endif
