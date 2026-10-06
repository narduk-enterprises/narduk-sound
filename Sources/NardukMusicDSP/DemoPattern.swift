import Foundation
import NardukMusicCore

/// A built-in 8-bar dubstep cycle for previews and manual listening when no conductor
/// exists: a 2-bar build (riser, accelerating snare roll, vocal "oh") into a 6-bar drop
/// that loops a 2-bar wobble riff in F minor, with an impact on the downbeat, FX
/// sprinkles and a tape stop out of the last bar.
public enum DemoPattern {
    public static let barsPerCycle = 8
    public static let stepsPerBar = 16

    public static func section(atStep step: Int) -> SongSection {
        let bar = (max(step, 0) / stepsPerBar) % barsPerCycle
        return bar < 2 ? .build : .drop
    }

    /// Every note whose step is in `range`.
    public static func notes(in range: ClosedRange<Int>) -> [ScheduledNote] {
        var result: [ScheduledNote] = []
        for step in range where step >= 0 { result.append(contentsOf: notes(atStep: step)) }
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func notes(atStep step: Int) -> [ScheduledNote] {
        guard step >= 0 else { return [] }
        let bar = step / stepsPerBar
        let cycle = bar / barsPerCycle
        let cycleBar = bar % barsPerCycle
        let pos = step % stepsPerBar
        var notes: [ScheduledNote] = []

        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) {
            notes.append(ScheduledNote(step: step, instrument: instrument, velocity: velocity, params: params))
        }

        if cycleBar < 2 {
            // BUILD
            if cycleBar == 0, pos == 0 {
                add(.kick, 0.9)
                add(.sub, 0.55, NoteParams(pitch: 29, lengthSteps: 16))
                add(.riser, 0.85, NoteParams(pitch: 48, lengthSteps: 32))
            }
            if pos % 2 == 0 { add(.hat, pos % 4 == 2 ? 0.55 : 0.4, NoteParams(pan: 0.2)) }
            if cycleBar == 0, pos % 4 == 0 {
                add(.snare, 0.45 + Double(pos) * 0.012)
            }
            if cycleBar == 1 {
                if pos < 8, pos % 2 == 0 { add(.snare, 0.6 + Double(pos) * 0.02) }
                if pos >= 8, pos <= 13 { add(.snare, 0.72 + Double(pos - 8) * 0.05) }
                if pos == 12 { add(.vox, 0.8, NoteParams(pitch: 53, lengthSteps: 3)) }
            }
            return notes
        }

        // DROP: a 2-bar riff, A on even bars, B on odd bars.
        let isA = cycleBar % 2 == 0
        let voice = cycle * 3 + (cycleBar >= 6 ? 3 : 0)
        let drive = cycleBar >= 6 ? 0.85 : 0.7

        if cycleBar == 2, pos == 0 { add(.impact, 1.0) }
        if pos == 0 || (isA && pos == 10) || (!isA && pos == 3) { add(.kick, pos == 0 ? 1.0 : 0.8) }
        if pos == 8 { add(.snare, 1.0) }
        if !isA, pos == 15 { add(.snare, 0.35) }
        if pos % 2 == 0, !(isA && pos == 14) { add(.hat, pos % 4 == 2 ? 0.6 : 0.42, NoteParams(pan: 0.2)) }
        if isA, pos == 14 { add(.openHat, 0.6, NoteParams(pan: -0.2)) }

        let riffA: [(Int, Int, Int, WobbleRate)] = [
            (0, 4, 41, .eighth), (4, 2, 41, .sixteenth),
            (6, 2, 44, .sixteenth), (8, 8, 41, .eighthTriplet),
        ]
        let riffB: [(Int, Int, Int, WobbleRate)] = [
            (0, 4, 37, .quarter), (4, 4, 37, .eighth),
            (8, 4, 39, .sixteenth), (12, 4, 36, .sixteenthTriplet),
        ]
        for (start, length, pitch, rate) in isA ? riffA : riffB where start == pos {
            add(
                .wobble, 0.95,
                NoteParams(
                    pitch: pitch, lengthSteps: length, wobbleRate: rate,
                    formant: isA ? 0.8 : 0.3, drive: drive, voice: voice))
            add(.sub, 0.9, NoteParams(pitch: pitch, lengthSteps: length))
        }

        if !isA, pos == 14 { add(.laser, 0.7, NoteParams(pitch: 96, pan: cycleBar == 3 ? -0.5 : 0.5)) }
        if cycleBar == 4, pos == 12 { add(.scratch, 0.8, NoteParams(lengthSteps: 2, pan: 0.3)) }
        if cycleBar == 5, pos == 14 { add(.glitch, 0.8, NoteParams(lengthSteps: 2)) }
        if cycleBar == 3, pos == 12 { add(.vox, 0.7, NoteParams(pitch: 56, lengthSteps: 2, pan: -0.3)) }
        if cycleBar == 7, pos == 12 { add(.tapeStop, 1.0, NoteParams(lengthSteps: 4)) }
        return notes
    }
}
