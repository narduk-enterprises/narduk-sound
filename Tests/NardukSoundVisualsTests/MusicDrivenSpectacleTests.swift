#if canImport(SwiftUI)
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// The visual state with a `MusicContext`: a build carries its phrase arc, a section change shifts the palette, and
    /// with `music: nil` none of that appears.
    @MainActor @Suite struct MusicDrivenSpectacleTests {
        /// Runs a scripted source: a snare every `every` frames, in `section`, with `phraseProgress` when music is on.
        static func run(
            frames: Int, snareEvery every: Int = 20, section: SongSection = .drop, phrase: Float = 0,
            music: Bool = true, calm: Bool = false
        ) -> (state: SoundVisualState, Void) {
            let state = SoundVisualState(seed: 5)
            var counts = HitCounters()
            var now = 1.0
            for i in 0..<frames {
                if i > 0, i % every == 0 { counts.record(.snare) }
                var context = MusicContext(
                    hitCounts: counts, step: i / 4, section: section, energy: 0.8, isRunning: true)
                context.phraseProgress = phrase
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(i + 1), level: 0.5), music: music ? context : nil)
                state.update(input, now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return (state, ())
        }

        @Test func aBuildCarriesItsPhraseArc() {
            let building = Self.run(frames: 60, section: .build, phrase: 0.6).state
            #expect(building.phraseProgress > 0)
        }

        @Test func withoutMusicThePhraseArcNeverDraws() throws {
            let state = Self.run(frames: 60, section: .build, phrase: 0.6, music: false).state
            #expect(state.phraseProgress == 0)
        }

        @Test func aSectionChangeShiftsThePalette() {
            let state = SoundVisualState(seed: 5)
            var now = 1.0
            func step(_ section: SongSection, frames: Int) {
                for i in 0..<frames {
                    let music = MusicContext(step: i, section: section, energy: 0.6, isRunning: true)
                    state.update(SoundVisualInput(frame: Script.frame(UInt64(i + 1)), music: music), now: now)
                    now += 1.0 / 60
                }
            }
            step(.intro, frames: 120)
            let intro = state.palette
            step(.drop, frames: 120)
            #expect(state.palette != intro)
        }
    }
#endif
