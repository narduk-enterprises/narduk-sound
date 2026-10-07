import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// The pitch state the piano roll and the pitch-class wheel draw from: a known note sequence must give the expected
/// roll cells, pitch classes and key, and raw audio (chroma only) must drive the wheel and the fallback roll.
@MainActor @Suite struct MusicalStateTests {
    static let columnTime = SoundMusicalState.rollSecondsPerColumn

    /// Drives `state` for `seconds` of 60 Hz frames, with `music(second)` supplying the context at each moment.
    static func run(
        _ state: SoundVisualState, seconds: Double, from start: Double = 1, chroma: [Float]? = nil,
        music: (Double) -> MusicContext?
    ) -> Double {
        var now = start
        var sequence: UInt64 = 1
        let end = start + seconds
        while now < end {
            var frame = Script.frame(sequence)
            if let chroma { frame.chroma = chroma } else { frame.chroma = [Float](repeating: 0, count: 12) }
            state.update(SoundVisualInput(frame: frame, music: music(now - start)), now: now)
            now += 1.0 / 60
            sequence += 1
        }
        return now
    }

    static func music(
        held: NoteSet = NoteSet(), counts: NoteCounters = NoteCounters(), key: Int? = nil, minor: Bool? = nil
    ) -> MusicContext {
        MusicContext(isRunning: true, heldNotes: held, noteCounts: counts, keyPitchClass: key, keyIsMinor: minor)
    }

    static func cell(_ musical: SoundMusicalState, age: Int, note: Int) -> Float {
        guard let column = musical.column(age: age) else { return -1 }
        return musical.roll[column * SoundMusicalState.noteCount + note]
    }

    @Test func aStruckNoteLandsInTheRollAndSustainsThroughItsLength() {
        let state = SoundVisualState(seed: 1)
        var counts = NoteCounters()
        // C4 struck at 0.5 s and held until 1.0 s, nothing else.
        let end = Self.run(state, seconds: 2) { t in
            var held = NoteSet()
            if t >= 0.5 && t < 1.0 { held.insert(60) }
            if abs(t - 0.5) < 0.009 && counts[60] == 0 { counts.record(60) }
            return Self.music(held: held, counts: counts)
        }
        #expect(end > 3)
        let musical = state.musical
        #expect(musical.hasNotes)
        #expect(musical.noteRange == 60...60)
        // Walk the roll from the oldest column: empty, one onset, sustain, empty again.
        var levels: [Float] = []
        for age in stride(from: musical.rollCount - 1, through: 0, by: -1) {
            levels.append(Self.cell(musical, age: age, note: 60))
        }
        let onsets = levels.filter { $0 == SoundMusicalState.onsetLevel }.count
        let sustained = levels.filter { $0 == SoundMusicalState.sustainLevel }.count
        #expect(onsets == 1, "one strike, one onset column: \(levels)")
        let expectedSustain = Int((0.5 / Self.columnTime).rounded())
        #expect(
            abs(sustained - expectedSustain) <= 2, "\(sustained) sustained columns, expected about \(expectedSustain)")
        let firstLit = levels.firstIndex { $0 > 0 } ?? -1
        #expect(levels[firstLit] == SoundMusicalState.onsetLevel, "a note begins with its onset")
        #expect(levels.last == 0, "the note has ended by the newest column")
        // No other note ever lit.
        for note in 0..<SoundMusicalState.noteCount where note != 60 {
            for age in 0..<musical.rollCount { #expect(Self.cell(musical, age: age, note: note) == 0) }
        }
    }

    @Test func aNoteStruckAndReleasedBetweenTwoFramesStillShowsAnOnset() {
        let state = SoundVisualState(seed: 1)
        let end = Self.run(state, seconds: 0.5) { _ in Self.music() }
        var counts = NoteCounters()
        counts.record(72)
        // The note is gone by the time the state polls (held is empty) but its counter moved.
        _ = Self.run(state, seconds: 0.2, from: end) { _ in Self.music(counts: counts) }
        var seen = false
        for age in 0..<state.musical.rollCount
        where Self.cell(state.musical, age: age, note: 72) == SoundMusicalState.onsetLevel { seen = true }
        #expect(seen)
    }

    @Test func aChordLightsItsThreePitchClassesAndNoOthers() {
        let state = SoundVisualState(seed: 1)
        _ = Self.run(state, seconds: 1.5) { _ in Self.music(held: NoteSet([48, 64, 67, 79])) }
        let classes = state.musical.pitchClasses
        for pitchClass in [0, 4, 7] {
            #expect(classes[pitchClass] > 0.95, "class \(pitchClass) = \(classes[pitchClass])")
        }
        for pitchClass in [1, 2, 3, 5, 6, 8, 9, 10, 11] { #expect(classes[pitchClass] < 0.05) }
    }

    @Test func theWheelReleasesAfterTheNotesEnd() {
        let state = SoundVisualState(seed: 1)
        let end = Self.run(state, seconds: 1) { _ in Self.music(held: NoteSet([60])) }
        #expect(state.musical.pitchClasses[0] > 0.95)
        _ = Self.run(state, seconds: 3, from: end) { _ in Self.music() }
        #expect(state.musical.pitchClasses[0] < 0.05)
    }

    @Test func rawAudioDrivesTheWheelFromItsChroma() {
        let state = SoundVisualState(seed: 1)
        var chroma = [Float](repeating: 0, count: 12)
        chroma[9] = 1  // A440
        chroma[4] = 0.5
        _ = Self.run(state, seconds: 1.5, chroma: chroma) { _ in nil }
        let classes = state.musical.pitchClasses
        #expect(!state.musical.hasNotes)
        #expect(classes[9] > 0.95 && abs(classes[4] - 0.5) < 0.05 && classes[0] < 0.05)
    }

    @Test func rawAudioFillsTheChromaRollNotTheNoteRoll() {
        let state = SoundVisualState(seed: 1)
        var chroma = [Float](repeating: 0, count: 12)
        chroma[9] = 1
        _ = Self.run(state, seconds: 1, chroma: chroma) { _ in nil }
        let musical = state.musical
        #expect(musical.noteRange == nil)
        #expect(musical.rollCount > 10)
        let newest = musical.column(age: 0) ?? 0
        #expect(musical.chromaRoll[newest * 12 + 9] > 0.9 && musical.chromaRoll[newest * 12 + 2] < 0.05)
    }

    @Test func aMusicSourceThatStopsPlayingNotesFallsBackToChroma() {
        let state = SoundVisualState(seed: 1)
        var chroma = [Float](repeating: 0, count: 12)
        chroma[2] = 1
        let end = Self.run(state, seconds: 1, chroma: chroma) { _ in Self.music(held: NoteSet([60])) }
        #expect(state.musical.hasNotes)
        _ = Self.run(state, seconds: 4, from: end, chroma: chroma) { _ in Self.music() }
        #expect(!state.musical.hasNotes)
        #expect(state.musical.pitchClasses[2] > 0.9, "after the note memory the wheel reads the audio")
    }

    @Test func theRollKeepsOnlyItsWindow() {
        let state = SoundVisualState(seed: 1)
        var counts = NoteCounters()
        counts.record(60)
        _ = Self.run(state, seconds: 0.3) { _ in Self.music(held: NoteSet([60]), counts: counts) }
        #expect(state.musical.noteRange == 60...60)
        // Longer than the window with nothing held: the old note scrolls out and the range empties.
        let window = Double(SoundMusicalState.rollColumns) * Self.columnTime
        _ = Self.run(state, seconds: window + 1, from: 3) { _ in Self.music(counts: counts) }
        #expect(state.musical.rollCount == SoundMusicalState.rollColumns)
        #expect(state.musical.noteRange == nil)
    }

    @Test func aMajorScaleSaysMajorAndNamesTheTonic() {
        let state = SoundVisualState(seed: 1)
        // D major scale, played over and over: D E F# G A B C#.
        let scale = [62, 64, 66, 67, 69, 71, 73, 74]
        var counts = NoteCounters()
        _ = Self.run(state, seconds: 20) { t in
            let note = scale[Int(t / 0.25) % scale.count]
            if abs(t.truncatingRemainder(dividingBy: 0.25)) < 0.009 { counts.record(note) }
            return Self.music(held: NoteSet([note]), counts: counts)
        }
        #expect(state.musical.keyPitchClass == 2, "D, got \(String(describing: state.musical.keyPitchClass))")
        #expect(!state.musical.keyIsMinor)
        #expect(state.musical.keyConfidence > 0.2)
    }

    @Test func aMinorKeyFromRawChromaIsFound() {
        let state = SoundVisualState(seed: 1)
        // A natural minor scale: A B C D E F G.
        var chroma = [Float](repeating: 0, count: 12)
        for pitchClass in [9, 11, 0, 2, 4, 5, 7] { chroma[pitchClass] = 0.6 }
        chroma[9] = 1
        chroma[4] = 0.8
        chroma[0] = 0.8
        _ = Self.run(state, seconds: 12, chroma: chroma) { _ in nil }
        #expect(state.musical.keyPitchClass == 9)
        #expect(state.musical.keyIsMinor)
    }

    @Test func aSourceThatStatesItsKeyIsBelieved() {
        let state = SoundVisualState(seed: 1)
        _ = Self.run(state, seconds: 0.3) { _ in Self.music(key: 6, minor: true) }
        #expect(state.musical.keyPitchClass == 6 && state.musical.keyIsMinor && state.musical.keyConfidence == 1)
    }

    @Test func silenceHasNoKey() {
        let state = SoundVisualState(seed: 1)
        _ = Self.run(state, seconds: 3) { _ in nil }
        #expect(state.musical.keyPitchClass == nil && state.musical.keyConfidence == 0)
    }

    @Test func rowsFitThePlayedRangeAndNeverLeaveMidiRange() {
        #if canImport(SwiftUI)
            #expect(SoundVisualizers.rollRows(nil) == nil)
            let one = SoundVisualizers.rollRows(60...60)
            #expect(one != nil && one!.count >= 24 && one!.contains(60))
            let low = SoundVisualizers.rollRows(0...3)
            #expect(low!.lowerBound == 0 && low!.count >= 24)
            let high = SoundVisualizers.rollRows(120...127)
            #expect(high!.upperBound == 127 && high!.count >= 24)
            let wide = SoundVisualizers.rollRows(20...100)
            #expect(wide!.contains(20) && wide!.contains(100))
        #endif
    }

    @Test func pitchClassesNameThemselves() {
        #expect(SoundMusicalState.name(ofPitchClass: 0) == "C")
        #expect(SoundMusicalState.name(ofPitchClass: 9) == "A")
        #expect(SoundMusicalState.name(ofPitchClass: -1) == "B")
        #expect(SoundMusicalState.name(ofPitchClass: 13) == "C♯")
    }
}
