import Foundation
import NardukMusicCore
import NardukMusicEngine

/// Writes notes for a `GallerySong` and hands them to `DropEngine.noteProvider`. A genre song runs a `DropConductor`
/// on a scripted energy curve (a 32 s loop: build, a queued drop, hold, fall away) so the song moves through its
/// sections without any data behind it; the guitar song is a fixed part that repeats every 16 bars.
@MainActor final class SongPlayer {
    private let song: GallerySong
    private var conductor: DropConductor?
    private var nextSignal = 0
    private var droppedInLoop = -1
    private var cursor = -1
    private weak var engine: DropEngine?

    /// Seconds between the scripted energy signals.
    static let signalInterval = 0.25
    /// The scripted curve repeats at this length.
    static let loopSeconds = 32.0

    init(song: GallerySong, engine: DropEngine) {
        self.song = song
        self.engine = engine
        if song.style.usesConductor { conductor = DropConductor(settings: song.settings) }
    }

    /// Energy 0 ... 1 `seconds` into the song: a build to 16 s, a hold, then a fall.
    static func energy(at seconds: Double) -> Double {
        let t = seconds.truncatingRemainder(dividingBy: loopSeconds)
        if t < 16 { return 0.12 + 0.76 * t / 16 }
        if t < 24 { return 0.9 }
        return 0.9 - 0.72 * (t - 24) / 8
    }

    func notes(through throughStep: Int) -> [ScheduledNote] {
        if throughStep < cursor {  // the engine restarted from step 0
            cursor = -1
            nextSignal = 0
            droppedInLoop = -1
            if song.style.usesConductor { conductor = DropConductor(settings: song.settings) }
        }
        guard throughStep > cursor else { return [] }
        defer { cursor = throughStep }
        switch song.style {
        case .genre, .ambient: return conductorNotes(through: throughStep)
        case .guitars: return GuitarPart.notes(in: (cursor + 1)...throughStep, seed: song.seed)
        case .demo: return []
        }
    }

    private func conductorNotes(through throughStep: Int) -> [ScheduledNote] {
        guard var conductor else { return [] }
        let seconds = Double(throughStep) * song.settings.secondsPerStep
        while Double(nextSignal) * Self.signalInterval <= seconds {
            let time = Double(nextSignal) * Self.signalInterval
            conductor.ingest(MusicSignal(time: time, level: Self.energy(at: time)))
            let loop = Int(time / Self.loopSeconds)
            if time.truncatingRemainder(dividingBy: Self.loopSeconds) >= 15, droppedInLoop != loop {
                droppedInLoop = loop
                conductor.queueDrop()
            }
            nextSignal += 1
        }
        let notes = conductor.advance(throughStep: throughStep)
        engine?.section = conductor.snapshot.section
        self.conductor = conductor
        return notes
    }
}

/// A sixteen-bar part for the guitar instruments (narduk-libs#1574): Am, F, C, G, four bars each pass. The first eight
/// bars are acoustic (strums, a picked line, a bass guitar); the last eight are electric (driven strums and lead).
enum GuitarPart {
    static let barSteps = 16
    static let bars = 16
    /// Chord roots (MIDI) and whether the chord is minor, per bar of the four-bar progression.
    private static let progression: [(root: Int, minor: Bool)] = [(45, true), (41, false), (48, false), (43, false)]

    static func notes(in steps: ClosedRange<Int>, seed: UInt64) -> [ScheduledNote] {
        var out: [ScheduledNote] = []
        for step in steps {
            let loopStep = step % (barSteps * bars)
            let bar = loopStep / barSteps
            let inBar = loopStep % barSteps
            let chord = progression[bar % progression.count]
            let electric = bar >= bars / 2
            let voice = chord.minor ? 1 : 0

            if inBar == 0 || inBar == 8 {
                out.append(
                    ScheduledNote(
                        step: step, instrument: electric ? .electricStrum : .strum, velocity: inBar == 0 ? 0.9 : 0.7,
                        params: NoteParams(
                            pitch: chord.root, lengthSteps: 8, formant: inBar == 8 ? 1 : 0,
                            drive: electric ? 0.6 : nil, voice: voice)))
            }
            if inBar == 0 || inBar == 10 {
                out.append(
                    ScheduledNote(
                        step: step, instrument: .bassGuitar, velocity: 0.85,
                        params: NoteParams(pitch: chord.root - 12, lengthSteps: 6)))
            }
            // A picked line on the chord tones, a different one each bar from the seed.
            if inBar % 2 == 0, inBar >= 4 {
                let tones = [0, 7, 12, 3 + (chord.minor ? 0 : 1), 7, 12, 15, 12]
                let pick = Int((seed &+ UInt64(bar * 8 + inBar / 2)) % UInt64(tones.count))
                out.append(
                    ScheduledNote(
                        step: step, instrument: electric ? .electricGuitar : .acousticGuitar, velocity: 0.6,
                        params: NoteParams(
                            pitch: chord.root + 12 + tones[pick], lengthSteps: 3, drive: electric ? 0.6 : nil)))
            }
        }
        return out
    }
}
