#if canImport(SwiftUI) && canImport(Darwin)
    import NardukMusicCore
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// The geometry a Canvas visualizer works out each frame from the state (the scope trigger, the Mirror's band
    /// weights, each pad's palette position and every read of the state's fixed buffers) must not allocate: they run at
    /// 60 Hz for every card on screen. Drawing itself builds SwiftUI `Path`s, as the apps it came from did; what the
    /// port removed is every per-frame array. Needs an optimized build, as `SoundVisualStateAllocationTests` does:
    /// run it under `swift test -c release`.
    @MainActor @Suite(.serialized) struct CanvasAllocationTests {
        @Test(.enabled(if: SoundVisualStateAllocationTests.optimized, "allocation counts need swift test -c release"))
        func theDrawStatePathNeverAllocates() throws {
            let state = CanvasVisualizerTests.busyState()
            let instruments = Instrument.allCases
            var sink: Float = 0
            let count = try SoundVisualStateAllocationTests.countAllocations {
                for _ in 0..<2_000 {
                    sink += Float(SoundVisualizers.scopeTrigger(state.waveform))
                    var total: CGFloat = 0
                    for band in 0..<SoundVisualState.bandCount {
                        total += SoundVisualizers.mirrorWeight(band, state.dropAmount)
                        sink += state.spectrum[band] + state.peaks[band]
                    }
                    sink += Float(total)
                    for instrument in instruments {
                        sink += SoundVisualizers.padPosition(instrument) + state.padBrightness[instrument.index]
                    }
                    for particle in state.particles where particle.life > 0 { sink += particle.age }
                    sink += state.history[state.historyHead] + state.waveform[0]
                }
            }
            #expect(count == 0, "the draw-state path allocated \(count) times")
            #expect(sink.isFinite)
        }
    }
#endif
