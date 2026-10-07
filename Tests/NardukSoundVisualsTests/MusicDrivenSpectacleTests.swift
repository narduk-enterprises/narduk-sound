#if canImport(SwiftUI)
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// The spectacle visualizers with a `MusicContext`: snare hits ratchet the kaleidoscope, a build fills the particle
    /// field's arc, and with `music: nil` nothing of that appears.
    @MainActor @Suite struct MusicDrivenSpectacleTests {
        /// Runs a scripted source: a snare every `every` frames, in `section`, with `phraseProgress` when music is on.
        static func run(
            frames: Int, snareEvery every: Int = 20, section: SongSection = .drop, phrase: Float = 0,
            music: Bool = true, calm: Bool = false
        ) -> (state: SoundVisualState, rotation: KaleidoscopeRotation) {
            let state = SoundVisualState(seed: 5)
            let rotation = KaleidoscopeRotation()
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
                rotation.update(state: state)
                now += 1.0 / 60
            }
            return (state, rotation)
        }

        @Test func eachSnareStepsTheKaleidoscope() {
            let (_, rotation) = Self.run(frames: 130)  // snares at frames 20, 40 ... 120
            #expect(rotation.steps == 6)
            #expect(rotation.angle > 0)
        }

        @Test func withoutMusicTheKaleidoscopeNeverSteps() {
            let (_, rotation) = Self.run(frames: 130, music: false)
            #expect(rotation.steps == 0)
            #expect(rotation.angle == 0)
        }

        @Test func calmFreezesTheRatchet() {
            let (_, rotation) = Self.run(frames: 130, calm: true)
            #expect(rotation.steps == 0)
        }

        @Test func theAngleSettlesOnTheStep() {
            let (state, rotation) = Self.run(frames: 130)
            var now = state.time
            // Let the ease finish with no more snares.
            for i in 0..<120 {
                now += 1.0 / 60
                state.update(SoundVisualInput(frame: Script.frame(UInt64(500 + i)), music: nil), now: now)
                rotation.update(state: state)
            }
            let wedge = 2 * Double.pi / Double(BeatKaleidoscope.foldCount(state))
            #expect(abs(rotation.angle - Double(rotation.steps) * wedge * 0.5) < 0.05)
        }

        @Test func aBuildFillsTheParticleFieldsArc() throws {
            let size = CGSize(width: 160, height: 160)
            func render(_ state: SoundVisualState) -> [Double]? {
                SpectacleGolden.signature(
                    of: Canvas { context, size in ParticleField.draw(into: &context, size: size, state: state) },
                    size: size)
            }
            let building = Self.run(frames: 60, section: .build, phrase: 0.6).state
            let flat = Self.run(frames: 60, section: .build, phrase: 0).state
            let withArc = try #require(render(building))
            let withoutArc = try #require(render(flat))
            #expect(withArc != withoutArc)
            #expect(withArc.reduce(0, +) > withoutArc.reduce(0, +))
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
