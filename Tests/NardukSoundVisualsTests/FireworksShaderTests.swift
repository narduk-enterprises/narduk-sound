#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// Bass and kick launch the shells (size and spark count follow the bass). Mids pick the shell type and slide
    /// colour. Highs twinkle. Snare and hat crackle. Drop amount fires a bounded volley. Calm is slower and softer.
    @MainActor @Suite struct FireworksShaderTests {
        static let size = (width: 192, height: 108)

        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer {
            let device = try #require(MTLCreateSystemDefaultDevice())
            if ShaderPackRenderer(device: device) == nil {
                let options = MTLCompileOptions()
                options.mathMode = .fast
                do { _ = try device.makeLibrary(source: ShaderPackSource.source, options: options) } catch {
                    Issue.record("fireworks shader failed to compile: \(error)")
                }
            }
            return try #require(ShaderPackRenderer(device: device), "the fireworks shader did not compile")
        }

        static func luma(_ pixels: [UInt8], width: Int, height: Int, y0: Int, y1: Int) -> Float {
            var sum: Float = 0
            var n: Float = 0
            let lo = max(y0, 0)
            let hi = min(y1, height)
            for y in lo..<hi {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    sum += (Float(pixels[i]) + Float(pixels[i + 1]) + Float(pixels[i + 2])) / (255 * 3)
                    n += 1
                }
            }
            return n > 0 ? sum / n : 0
        }

        /// Upper sky, where the bursts sit. Texture row 0 is the top of the frame.
        static func skyLuma(_ pixels: [UInt8], width: Int, height: Int) -> Float {
            luma(pixels, width: width, height: height, y0: 0, y1: height * 62 / 100)
        }

        static func render(
            _ state: SoundVisualState, calm: Bool = false, width: Int = size.width, height: Int = size.height
        ) throws -> [UInt8] {
            try #require(
                renderer().renderOffscreen(.fireworks, state: state, width: width, height: height, calm: calm))
        }

        /// `bass` / `highs` override those bands; nil keeps `Script.frame`'s slope. Hit counters accumulate, so a kick
        /// is an edge rather than a level that stays stuck on.
        static func show(
            frames: Int, level: Float, energy: Float, section: SongSection, bass: Float?, highs: Float?,
            kickEvery: Int?, snareEvery: Int?, calm: Bool
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 42)
            var counts = HitCounters()
            var now = 1.0
            for i in 0..<frames {
                if let kickEvery, i > 0, i % kickEvery == 0 { counts.record(.kick) }
                if let snareEvery, i > 0, i % snareEvery == 0 { counts.record(.snare) }
                var frame = Script.frame(UInt64(i + 1), level: level, rmsDB: level > 0.01 ? -16 : -120)
                if let bass {
                    for band in 0..<10 { frame.spectrum[band] = bass }
                }
                if let highs {
                    for band in 36..<SoundFrame.spectrumCount { frame.spectrum[band] = highs }
                }
                let music = MusicContext(
                    hitCounts: counts, step: i / 4, section: section, energy: energy, isRunning: energy > 0.05)
                state.update(
                    SoundVisualInput(frame: frame, music: music), now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func writePPM(_ pixels: [UInt8], width: Int, height: Int, path: String) throws {
            var rgb = [UInt8]()
            rgb.reserveCapacity(width * height * 3)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    rgb.append(pixels[i + 2])
                    rgb.append(pixels[i + 1])
                    rgb.append(pixels[i])
                }
            }
            var data = Data("P6\n\(width) \(height)\n255\n".utf8)
            data.append(contentsOf: rgb)
            try data.write(to: URL(fileURLWithPath: path))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func bassChangesThePictureMoreThanHighs() throws {
            let quiet = Self.show(
                frames: 96, level: 0, energy: 0, section: .intro, bass: 0, highs: 0, kickEvery: nil, snareEvery: nil,
                calm: false)
            let bass = Self.show(
                frames: 96, level: 0.35, energy: 0.82, section: .drop, bass: 0.95, highs: 0.08, kickEvery: 16,
                snareEvery: 32, calm: false)
            let highs = Self.show(
                frames: 96, level: 0.35, energy: 0.82, section: .drop, bass: 0.06, highs: 0.95, kickEvery: 16,
                snareEvery: 32, calm: false)
            let quietPx = try Self.render(quiet)
            let bassPx = try Self.render(bass)
            let highsPx = try Self.render(highs)
            #expect(bassPx != quietPx)
            let bassLift =
                Self.skyLuma(bassPx, width: Self.size.width, height: Self.size.height)
                - Self.skyLuma(quietPx, width: Self.size.width, height: Self.size.height)
            let highsLift =
                Self.skyLuma(highsPx, width: Self.size.width, height: Self.size.height)
                - Self.skyLuma(quietPx, width: Self.size.width, height: Self.size.height)
            #expect(bassLift > highsLift + 0.008, "bass lift \(bassLift) vs highs lift \(highsLift)")
            #expect(bassLift > 0.015)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSameStateRendersTheSamePicture() throws {
            let state = Self.show(
                frames: 96, level: 0.55, energy: 0.8, section: .drop, bass: nil, highs: nil, kickEvery: 15,
                snareEvery: 30, calm: false)
            let first = try Self.render(state)
            let second = try Self.render(state)
            #expect(first == second)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func calmIsSofterAndStillAPicture() throws {
            let loud = Self.show(
                frames: 96, level: 0.6, energy: 0.85, section: .drop, bass: 0.8, highs: 0.3, kickEvery: 12,
                snareEvery: 24, calm: false)
            let calm = Self.show(
                frames: 96, level: 0.6, energy: 0.85, section: .drop, bass: 0.8, highs: 0.3, kickEvery: 12,
                snareEvery: 24, calm: true)
            let loudPx = try Self.render(loud, calm: false)
            let calmPx = try Self.render(calm, calm: true)
            let loudMean = Self.luma(
                loudPx, width: Self.size.width, height: Self.size.height, y0: 0, y1: Self.size.height)
            let calmMean = Self.luma(
                calmPx, width: Self.size.width, height: Self.size.height, y0: 0, y1: Self.size.height)
            #expect(calmMean > 0.01, "calm drew nothing (\(calmMean))")
            #expect(calmMean < 0.55, "calm is too bright (\(calmMean))")
            #expect(calmPx != loudPx)
            #expect(calmMean < loudMean)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aShowIsNeitherBlankNorWhite() throws {
            let state = WobbleTunnelTests.busyState()
            let pixels = try Self.render(state)
            let mean = Self.luma(pixels, width: Self.size.width, height: Self.size.height, y0: 0, y1: Self.size.height)
            #expect(mean > 0.02, "fireworks drew nothing (\(mean))")
            #expect(mean < 0.75, "fireworks blew out to white (\(mean))")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aKickBrightensTheSky() throws {
            let rest = Self.show(
                frames: 97, level: 0.5, energy: 0.8, section: .drop, bass: 0.75, highs: 0.2, kickEvery: nil,
                snareEvery: nil, calm: false)
            let kick = Self.show(
                frames: 97, level: 0.5, energy: 0.8, section: .drop, bass: 0.75, highs: 0.2, kickEvery: 96,
                snareEvery: nil, calm: false)
            let restPx = try Self.render(rest)
            let kickPx = try Self.render(kick)
            #expect(kickPx != restPx)
            #expect(
                Self.skyLuma(kickPx, width: Self.size.width, height: Self.size.height)
                    > Self.skyLuma(restPx, width: Self.size.width, height: Self.size.height) + 0.004)
        }

        /// Headless stills for the look review. Set `NARDUK_FIREWORKS_DIR` to a directory; otherwise this does nothing.
        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func writesReviewStillsWhenAsked() throws {
            guard let dir = ProcessInfo.processInfo.environment["NARDUK_FIREWORKS_DIR"] else { return }
            let width = 640
            let height = 360
            let quiet = Self.show(
                frames: 96, level: 0, energy: 0, section: .intro, bass: 0, highs: 0, kickEvery: nil, snareEvery: nil,
                calm: false)
            let loud = Self.show(
                frames: 100, level: 0.7, energy: 0.9, section: .drop, bass: 0.95, highs: 0.35, kickEvery: 15,
                snareEvery: 30, calm: false)
            let drop = Self.show(
                frames: 76, level: 0.75, energy: 0.95, section: .drop, bass: 0.9, highs: 0.4, kickEvery: 15,
                snareEvery: 30, calm: false)
            let busy = WobbleTunnelTests.busyState()
            let shots: [(String, SoundVisualState)] = [
                ("quiet", quiet), ("loud", loud), ("drop", drop), ("busy", busy),
            ]
            for shot in shots {
                let pixels = try Self.render(shot.1, width: width, height: height)
                let mean = Self.luma(pixels, width: width, height: height, y0: 0, y1: height)
                let sky = Self.skyLuma(pixels, width: width, height: height)
                print("FIREWORKS \(shot.0) mean=\(mean) sky=\(sky)")
                try Self.writePPM(pixels, width: width, height: height, path: "\(dir)/\(shot.0).ppm")
            }
            let goldenPx = try Self.render(busy, width: 96, height: 64)
            let cells = WobbleTunnelTests.grid(goldenPx, width: 96, height: 64, columns: 4, rows: 3)
            var luminance: [Float] = []
            for i in stride(from: 0, to: cells.count, by: 3) {
                luminance.append((cells[i] + cells[i + 1] + cells[i + 2]) / 3)
            }
            let formatted = luminance.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            print("GOLDEN fireworks: [\(formatted)]")
        }
    }
#endif
