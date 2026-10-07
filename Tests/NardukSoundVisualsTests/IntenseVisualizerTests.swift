#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct IntenseVisualizerTests {
        static let size = (width: 96, height: 64)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> IntenseRenderer {
            try #require(
                IntenseRenderer(device: MTLCreateSystemDefaultDevice()),
                "an intense shader did not compile or its pipeline could not be built")
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            WobbleTunnelTests.grid(pixels, width: size.width, height: size.height, columns: 1, rows: 1).reduce(0, +) / 3
        }

        static func render(_ kind: IntenseKind, frames: Int = 1, calm: Bool = false) throws -> [UInt8] {
            let state = SoundVisualState(seed: 42)
            var limiter = IntenseFlashLimiter()
            var now = 1.0
            var frame = 0
            func step() {
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(frame + 1), level: 0.6),
                    music: Script.music(
                        step: frame / 4, kicks: frame % 15 == 0 ? 1 : 0, snares: frame % 30 == 15 ? 1 : 0))
                state.update(input, now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
                frame += 1
            }
            for _ in 0..<90 { step() }
            return try #require(
                try renderer().renderOffscreen(
                    kind, state: state, width: size.width, height: size.height, frames: frames, limiter: &limiter,
                    advance: step))
        }

        @Test func uniformsKeepTheShaderLayoutAndCarryTheDrive() {
            #expect(MemoryLayout<IntenseUniforms>.size == 10 * 16)
            #expect(MemoryLayout<IntenseUniforms>.stride == 10 * 16)
            let state = WobbleTunnelTests.busyState()
            var limiter = IntenseFlashLimiter()
            var drive = IntenseDrive(state: state, limiter: &limiter)
            drive.flash = 0.25
            drive.glitch = 0.5
            var uniforms = IntenseUniforms()
            uniforms.fill(size: CGSize(width: 320, height: 200), state: state, drive: drive)
            #expect(uniforms.base.resTime.x == 320 && uniforms.base.env.x == state.kick)
            #expect(uniforms.extra.x == 0.25 && uniforms.extra.w == 0.5 && uniforms.extra.z == drive.intensity)
            #expect(uniforms.flashColor.w == (state.calm ? 1 : 0))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func everyVisualizerDrawsAPictureThatIsNeitherBlankNorWhite(kind: IntenseKind) throws {
            let mean = Self.mean(try Self.render(kind, frames: 12))
            #expect(mean > 0.005, "\(kind) drew nothing (mean \(mean))")
            #expect(mean < 0.85, "\(kind) is a white flash (mean \(mean))")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func theSameStateRendersTheSamePicture(kind: IntenseKind) throws {
            #expect(try Self.render(kind, frames: 6) == Self.render(kind, frames: 6))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func calmDrawsADifferentGentlerPicture(kind: IntenseKind) throws {
            let loud = try Self.render(kind, frames: 12)
            let calm = try Self.render(kind, frames: 12, calm: true)
            #expect(loud != calm)
        }

        /// The rendered flash, frame by frame: a strobing script on the drop never starts more than three full-screen
        /// flashes in any second, and the drive's flash is what the picture was drawn with.
        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func theRenderedFlashNeverExceedsThreePerSecond(kind: IntenseKind) throws {
            let state = SoundVisualState(seed: 7)
            var limiter = IntenseFlashLimiter()
            var now = 1.0
            var frame = 0
            var levels: [Float] = []
            var peak: Float = 0
            func step() {
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(frame + 1), level: 0.95),
                    music: Script.music(step: frame / 4, kicks: frame % 3 == 0 ? 1 : 0, snares: frame % 3 == 1 ? 1 : 0))
                state.update(input, now: now)
                now += 1.0 / 60
                frame += 1
            }
            for _ in 0..<60 { step() }
            _ = try #require(
                try Self.renderer().renderOffscreen(
                    kind, state: state, width: Self.size.width, height: Self.size.height, frames: 360,
                    limiter: &limiter, advance: step,
                    onFrame: { _, drive in
                        levels.append(drive.flash)
                        peak = max(peak, drive.flash)
                    }))
            #expect(levels.count == 360)
            #expect(IntenseSafetyTests.worstFlashesPerSecond(levels) <= IntenseFlashLimiter.maxFlashesPerSecond)
            #expect(peak <= IntenseFlashLimiter.maxLevel)
            #expect(peak > 0, "the script never asked for a flash, so the cap went untested")
        }

        /// Writes a still sequence of each visualizer as PPM files when `NARDUK_INTENSE_DEMO_DIR` is set (the lane's
        /// offline evidence; never runs in CI).
        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func writesDemoStillsWhenAskedTo(kind: IntenseKind) throws {
            guard let directory = ProcessInfo.processInfo.environment["NARDUK_INTENSE_DEMO_DIR"] else { return }
            let (width, height) = (640, 360)
            let state = SoundVisualState(seed: 7)
            var limiter = IntenseFlashLimiter()
            var now = 1.0
            var frame = 0
            func step() {
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(frame + 1), level: 0.8),
                    music: Script.music(
                        step: frame / 4, kicks: frame % 15 == 0 ? 1 : 0, snares: frame % 30 == 15 ? 1 : 0))
                state.update(input, now: now)
                now += 1.0 / 60
                frame += 1
            }
            for _ in 0..<60 { step() }
            let renderer = try Self.renderer()
            for shot in 0..<4 {
                let pixels = try #require(
                    renderer.renderOffscreen(
                        kind, state: state, width: width, height: height, frames: shot == 0 ? 90 : 45,
                        limiter: &limiter, advance: step))
                var ppm = Data("P6\n\(width) \(height)\n255\n".utf8)
                var index = 0
                while index < pixels.count {
                    ppm.append(contentsOf: [pixels[index + 2], pixels[index + 1], pixels[index]])
                    index += 4
                }
                try ppm.write(to: URL(fileURLWithPath: "\(directory)/\(kind.rawValue)-\(shot).ppm"))
                for _ in 0..<45 { step() }
            }
        }
    }
#endif
