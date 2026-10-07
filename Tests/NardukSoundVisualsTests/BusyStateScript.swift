import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// A scripted mid-song `SoundVisualState` for tests that need a busy, deterministic input.
enum BusyStateScript {
    /// A busy mid-song state: a kick on every beat, a snare on the backbeat, a wobble, a drop.
    @MainActor static func state(silent: Bool = false, look: SoundPaletteLook = .neutral) -> SoundVisualState {
        let state = SoundVisualState(seed: 42)
        state.look = look
        var now = 100.0
        var notes = NoteCounters()
        // A rising C minor arpeggio, one note every ten frames, each held for twenty-five.
        let arpeggio = [48, 55, 60, 63, 67, 72, 67, 63, 60, 55, 51, 58, 62, 65, 70]
        for i in 0..<150 {
            if i % 10 == 0 { notes.record(arpeggio[(i / 10) % arpeggio.count]) }
            var held = NoteSet()
            for back in 0..<3 {
                let started = (i / 10 - back) * 10
                if started >= 0, i - started < 25 { held.insert(arpeggio[(started / 10) % arpeggio.count]) }
            }
            let frame =
                silent
                ? SoundFrame(sequence: UInt64(i + 1), time: Double(i) / 60)
                : Script.frame(UInt64(i + 1), level: 0.55 + 0.3 * sin(Float(i) / 9))
            var counts = HitCounters()
            for _ in 0..<(i / 15) { counts.record(.kick) }
            for _ in 0..<(i / 30) { counts.record(.snare) }
            for _ in 0..<(i / 7) { counts.record(.hat) }
            if i > 60 { for _ in 0..<((i - 60) / 20) { counts.record(.wobble) } }
            let music = MusicContext(
                hitCounts: counts, step: i / 4, section: i < 50 ? .build : .drop, energy: 0.85,
                wobblePhase: Float(i % 40) / 40, wobbleCutoff: 0.5 + 0.35 * sin(Float(i) / 11), isRunning: true,
                heldNotes: held, noteCounts: notes)
            state.update(SoundVisualInput(frame: frame, music: silent ? nil : music), now: now)
            now += 1.0 / 60
        }
        return state
    }
}
