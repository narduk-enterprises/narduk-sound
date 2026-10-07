#if canImport(Metal)
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct SolarFlareShaderTests {
        static let size = (width: 96, height: 64)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer { try ShaderPackTests.renderer() }

        static func state(
            frames: Int = 48, bass: Float, mids: Float, highs: Float, kickAtEnd: Bool = false, calm: Bool = false,
            section: SongSection = .intro
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 7)
            var now = 1.0
            for index in 0..<frames {
                var spectrum = [Float](repeating: 0.02, count: SoundFrame.spectrumCount)
                for band in 0..<10 { spectrum[band] = bass }
                for band in 10..<36 { spectrum[band] = mids }
                for band in 36..<SoundFrame.spectrumCount { spectrum[band] = highs }
                let kicks: UInt32 = kickAtEnd && index == frames - 1 ? 1 : 0
                let db: Float = bass > 0.2 ? -12 : -36
                let frame = SoundFrame(
                    sequence: UInt64(index + 1), time: now, spectrum: spectrum, peakDB: db + 6, rmsDB: db)
                state.update(
                    SoundVisualInput(
                        frame: frame, music: Script.music(step: index / 4, kicks: kicks, section: section)),
                    now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func render(_ state: SoundVisualState, calm: Bool = false) throws -> [UInt8] {
            try #require(
                try renderer().renderOffscreen(
                    .solarFlare, state: state, width: size.width, height: size.height, calm: calm))
        }

        /// Mean luma of pixels whose polar radius (the shader's frame, height = 1) falls in `range`.
        static func luma(_ pixels: [UInt8], range: ClosedRange<Float>? = nil) -> Float {
            let width = size.width
            let height = size.height
            let aspect = Float(width) / Float(max(height, 1))
            var sum: Float = 0
            var count: Float = 0
            for y in 0..<height {
                for x in 0..<width {
                    let px = (Float(x) + 0.5) / Float(width) - 0.5
                    let py = (Float(y) + 0.5) / Float(height) - 0.5
                    let radius = hypot(px * aspect, py)
                    if let range, !range.contains(radius) { continue }
                    let index = (y * width + x) * 4
                    let blue = Float(pixels[index])
                    let green = Float(pixels[index + 1])
                    let red = Float(pixels[index + 2])
                    sum += (red + green + blue) / (255 * 3)
                    count += 1
                }
            }
            return count > 0 ? sum / count : 0
        }

        @Test func theKindIsTitledSolarFlare() {
            #expect(ShaderPackKind.solarFlare.title == "Solar flare")
            #expect(ShaderPackKind.solarFlare.fragmentName == "solarFlareFragment")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func bassPushesTheCoronaAndThePictureIsNotBlankOrWhite() throws {
            let quiet = try Self.render(Self.state(bass: 0.04, mids: 0.35, highs: 0.2))
            let loud = try Self.render(Self.state(bass: 1, mids: 0.35, highs: 0.2))
            let quietAll = Self.luma(quiet)
            let loudAll = Self.luma(loud)
            let quietCorona = Self.luma(quiet, range: 0.30...0.52)
            let loudCorona = Self.luma(loud, range: 0.30...0.52)
            #expect(quiet != loud, "bass did not change the picture")
            #expect(loudCorona > quietCorona + 0.012, "corona \(loudCorona) vs quiet \(quietCorona)")
            #expect(quietAll > 0.015 && quietAll < 0.85, "quiet mean \(quietAll)")
            #expect(loudAll > 0.02 && loudAll < 0.85, "loud mean \(loudAll)")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSameStateRendersTheSamePicture() throws {
            let state = Self.state(bass: 0.7, mids: 0.5, highs: 0.45, section: .drop)
            #expect(try Self.render(state) == Self.render(state))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func calmSlowsThePictureAndDropsTheKickFlare() throws {
            let kicked = Self.state(bass: 0.55, mids: 0.4, highs: 0.35, kickAtEnd: true)
            let live = try Self.render(kicked, calm: false)
            let calm = try Self.render(kicked, calm: true)
            let liveMean = Self.luma(live)
            let calmMean = Self.luma(calm)
            let liveLimb = Self.luma(live, range: 0.16...0.28)
            let calmLimb = Self.luma(calm, range: 0.16...0.28)
            #expect(live != calm)
            #expect(calmMean > 0.015 && calmMean < 0.85, "calm mean \(calmMean)")
            #expect(liveMean < 0.85, "live mean \(liveMean)")
            #expect(liveLimb > calmLimb, "kick limb \(liveLimb) vs calm \(calmLimb)")
        }
    }
#endif
