#if canImport(SwiftUI) && canImport(AppKit)
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// Geometry, reactivity, determinism and calm behavior of the Vortex canvas. The golden grid lives with the other
    /// canvas kinds in `CanvasVisualizerTests`; this file checks the pure helpers and that the bass, the kick and the
    /// highs each move their own part of the picture.
    @MainActor @Suite struct VortexCanvasesTests {
        static func bands(_ fill: (Int) -> Float) -> [Float] {
            (0..<SoundFrame.spectrumCount).map(fill)
        }

        /// A steady state with a given spectrum, optionally ending on a burst of kicks or snares.
        static func vortexState(
            spectrum: [Float], kicks: UInt32 = 0, snares: UInt32 = 0, section: SongSection = .build,
            calm: Bool = false
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 11)
            var now = 40.0
            var counts = HitCounters()
            let wave = (0..<SoundFrame.waveformCount).map { Float(sin(Double($0) / 7)) * 0.6 }
            for frameIndex in 0..<48 {
                let frame = SoundFrame(
                    sequence: UInt64(frameIndex + 1), time: Double(frameIndex) / 60, spectrum: spectrum,
                    waveform: wave, peakDB: -8, rmsDB: -14)
                if frameIndex == 47 {
                    for _ in 0..<kicks { counts.record(.kick) }
                    for _ in 0..<snares { counts.record(.snare) }
                }
                let music = MusicContext(
                    hitCounts: counts, step: 8 + frameIndex / 8, section: section, energy: 0.6, isRunning: true)
                state.update(
                    SoundVisualInput(frame: frame, music: music), now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func centerLuma(_ grid: [Int]) -> Int {
            let width = CanvasVisualizerTests.columns
            var sum = 0
            for row in 3...5 { for column in 6...9 { sum += grid[row * width + column] } }
            return sum
        }

        @Test func theHashIsDeterministicAndInRange() {
            for i in [0, 1, 7, 95, 1_000, 2_095, -3] {
                let a = SoundVisualizers.vortexHash(i)
                #expect(a >= 0 && a < 1)
                #expect(a == SoundVisualizers.vortexHash(i))
            }
            #expect(SoundVisualizers.vortexHash(3) != SoundVisualizers.vortexHash(4))
        }

        @Test func bandsMoveOutwardAlongAnArmAndALoudBandBulges() {
            var previous: CGFloat = -1
            for band in 0..<SoundVisualState.bandCount {
                let r = SoundVisualizers.vortexBandRadius(band, amplitude: 0)
                #expect(r > previous, "band \(band)")
                #expect(r > 0 && r <= 1)
                previous = r
            }
            #expect(
                SoundVisualizers.vortexBandRadius(20, amplitude: 1)
                    > SoundVisualizers.vortexBandRadius(20, amplitude: 0))
        }

        @Test func anArmSpiralsAndTheArmsAreEvenlySpaced() {
            let twist = SoundVisualizers.vortexTwist(drop: 0, wobble: 0)
            let inner = SoundVisualizers.vortexArmAngle(band: 0, arm: 0, rotation: 0, twist: twist)
            let outer = SoundVisualizers.vortexArmAngle(band: 63, arm: 0, rotation: 0, twist: twist)
            #expect(outer > inner + 1)
            let second = SoundVisualizers.vortexArmAngle(band: 0, arm: 1, rotation: 0, twist: twist)
            #expect(abs(second - inner - 2 * .pi / 3) < 1e-9)
            // Rotation turns the whole field.
            let turned = SoundVisualizers.vortexArmAngle(band: 0, arm: 0, rotation: 0.5, twist: twist)
            #expect(abs(turned - inner - 0.5) < 1e-9)
        }

        @Test func aDropWindsTheArmsTighter() {
            #expect(SoundVisualizers.vortexTwist(drop: 1, wobble: 0) > SoundVisualizers.vortexTwist(drop: 0, wobble: 0))
            #expect(SoundVisualizers.vortexTwist(drop: 0, wobble: 1) > SoundVisualizers.vortexTwist(drop: 0, wobble: 0))
        }

        @Test func theBassSwellsTheCoreMoreThanTheHighsDo() throws {
            let quiet = try CanvasVisualizerTests.grid(.vortex, Self.vortexState(spectrum: Self.bands { _ in 0.02 }))
            let bassy = try CanvasVisualizerTests.grid(
                .vortex, Self.vortexState(spectrum: Self.bands { $0 < 10 ? 0.95 : 0.02 }))
            let bright = try CanvasVisualizerTests.grid(
                .vortex, Self.vortexState(spectrum: Self.bands { $0 >= 36 ? 0.95 : 0.02 }))
            #expect(Self.centerLuma(bassy) > Self.centerLuma(quiet))
            #expect(Self.centerLuma(bassy) - Self.centerLuma(quiet) > Self.centerLuma(bright) - Self.centerLuma(quiet))
            // The highs still change the picture: the rim.
            #expect(CanvasVisualizerTests.drift(bright, quiet) > 0.5)
        }

        @Test func aKickBrightensTheCore() throws {
            let spectrum = Self.bands { _ in 0.3 }
            let plain = try CanvasVisualizerTests.grid(.vortex, Self.vortexState(spectrum: spectrum))
            let kicked = try CanvasVisualizerTests.grid(.vortex, Self.vortexState(spectrum: spectrum, kicks: 4))
            #expect(Self.centerLuma(kicked) > Self.centerLuma(plain))
        }

        @Test func aSnareThrowsAShockRing() throws {
            let spectrum = Self.bands { _ in 0.3 }
            let plain = try CanvasVisualizerTests.grid(.vortex, Self.vortexState(spectrum: spectrum))
            let hit = try CanvasVisualizerTests.grid(.vortex, Self.vortexState(spectrum: spectrum, snares: 4))
            #expect(CanvasVisualizerTests.drift(hit, plain) > 0.3)
        }

        @Test func theSamePictureTwiceIsIdentical() throws {
            let state = CanvasVisualizerTests.busyState()
            let a = try CanvasVisualizerTests.grid(.vortex, state)
            let b = try CanvasVisualizerTests.grid(.vortex, state)
            #expect(CanvasVisualizerTests.drift(a, b) == 0)
        }

        @Test func calmModeStillDrawsTheGalaxyWithoutAFlash() throws {
            let state = Self.vortexState(spectrum: Self.bands { _ in 0.5 }, kicks: 3, section: .drop, calm: true)
            #expect(state.flash == 0)
            let grid = try CanvasVisualizerTests.grid(.vortex, state)
            let blank = try CanvasVisualizerTests.grid(.vortex, SoundVisualState(seed: 11))
            #expect(CanvasVisualizerTests.drift(grid, blank) > 1.0)
        }

        @Test(.enabled(if: SoundVisualStateAllocationTests.optimized, "allocation counts need swift test -c release"))
        func theVortexGeometryNeverAllocates() throws {
            let state = CanvasVisualizerTests.busyState()
            var sink: Double = 0
            let count = try SoundVisualStateAllocationTests.countAllocations {
                for frame in 0..<2_000 {
                    let twist = SoundVisualizers.vortexTwist(drop: state.dropAmount, wobble: state.wobbleCutoff)
                    sink += Double(SoundVisualizers.vortexBandMean(state.spectrum, 0..<10))
                    sink += Double(SoundVisualizers.vortexBandMean(state.spectrum, 36..<64))
                    for band in 0..<SoundVisualState.bandCount {
                        sink += Double(SoundVisualizers.vortexBandRadius(band, amplitude: state.spectrum[band]))
                        sink += SoundVisualizers.vortexArmAngle(
                            band: band, arm: band % 3, rotation: state.travel, twist: twist)
                        sink += Double(state.peaks[band])
                    }
                    for k in 0..<SoundVisualizers.vortexStars { sink += Double(SoundVisualizers.vortexHash(k + frame)) }
                    for i in stride(from: 0, to: SoundVisualState.sampleCount, by: 4) {
                        sink += Double(state.waveform[i])
                    }
                }
            }
            #expect(count == 0, "the vortex geometry allocated \(count) times")
            #expect(sink.isFinite)
        }
    }
#endif
