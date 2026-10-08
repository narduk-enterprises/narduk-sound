#if canImport(AVFoundation)
    import Foundation
    import NardukMusicCore
    import NardukMusicDSP
    import NardukMusicRender
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What a Metal tile receives from `SoundVisualState` when the classic loop plays as the demo (the engine's own
    /// `MusicContext`) against the same loop heard back through `SoundMusicInference`: the kick and impact envelopes,
    /// the beat clock, energy, the drop amount and travel, a quarter second apart. `INFER_VISUAL=1` prints both.
    @Suite struct SoundVisualStateCompareTests {
        @MainActor
        static func log(inferred: Bool, seconds: Double = 10) -> [(Double, String)] {
            let settings = SongSettings()
            let renderer = OfflineRenderer(settings: settings, playsConductor: false)
            renderer.schedule(DemoPattern.notes(in: 0...(Int(seconds / settings.secondsPerStep) + 1)))
            let analyzer = SoundAnalyzer(sampleRate: renderer.sampleRate)
            let inference = SoundMusicInference()
            let state = SoundVisualState()
            var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
            var counts = HitCounters()
            var rows: [(Double, String)] = []
            var kickPeaks = 0
            var lastKick: Float = 0
            let ticks = Int(seconds * OfflineRenderer.tickRate)
            for tick in 0..<ticks {
                let time = Double(tick + 1) / OfflineRenderer.tickRate
                _ = renderer.advance()
                for hit in renderer.takeHits() { counts.record(hit) }
                window.withUnsafeMutableBufferPointer { renderer.copyRecentSamples(into: $0) }
                let frame = window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
                let music: MusicContext
                if inferred {
                    music = inference.update(frame)
                } else {
                    let step = renderer.currentStep
                    music = MusicContext(
                        hitCounts: counts, step: step, section: DemoPattern.section(atStep: step), energy: 0,
                        wobblePhase: 0, wobbleCutoff: 0, isRunning: true, secondsPerStep: settings.secondsPerStep,
                        stepsPerBar: settings.stepsPerBar, stepsPerPhrase: settings.stepsPerPhrase,
                        phraseProgress: Float(step % settings.stepsPerPhrase) / Float(settings.stepsPerPhrase),
                        buildThreshold: 0.55, dropThreshold: 0.4, dropQueued: false)
                }
                state.update(SoundVisualInput(frame: frame, music: music), now: time)
                if state.kick > 0.9, lastKick <= 0.9 { kickPeaks += 1 }
                lastKick = state.kick
                if tick % 15 == 14 {
                    rows.append(
                        (
                            time,
                            String(
                                format:
                                    "kick=%.2f snare=%.2f impact=%.2f flash=%.2f energy=%.2f drop=%.2f wild=%.2f beats=%.1f travel=%.1f running=%d section=%@ kicks=%d",
                                state.kick, state.snare, state.impact, state.flash, state.energy, state.dropAmount,
                                state.wild, state.beats, state.travel, state.isRunning ? 1 : 0, "\(music.section)",
                                kickPeaks)
                        ))
                }
            }
            return rows
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["INFER_VISUAL"] != nil))
        @MainActor func printBoth() {
            let demo = Self.log(inferred: false)
            let heard = Self.log(inferred: true)
            for (a, b) in zip(demo, heard) {
                print(String(format: "vs %5.2f demo  %@", a.0, a.1))
                print(String(format: "vs %5.2f heard %@", b.0, b.1))
            }
        }
    }
#endif
