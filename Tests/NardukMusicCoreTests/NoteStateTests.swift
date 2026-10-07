import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct NoteStateTests {
    @Test func aNoteSetHoldsAnyOfTheMidiNotes() {
        var set = NoteSet()
        #expect(set.isEmpty)
        for note in [0, 12, 63, 64, 69, 127] { set.insert(note) }
        #expect(set.count == 6)
        for note in [0, 12, 63, 64, 69, 127] { #expect(set.contains(note)) }
        #expect(!set.contains(1) && !set.contains(65) && !set.contains(126))
        set.remove(64)
        #expect(!set.contains(64) && set.count == 5)
    }

    @Test func aNoteSetIgnoresNotesOutsideMidiRange() {
        var set = NoteSet()
        set.insert(-1)
        set.insert(128)
        #expect(set.isEmpty)
        #expect(!set.contains(-1) && !set.contains(128))
    }

    @Test func pitchClassesFoldEveryOctave() {
        let set = NoteSet([60, 64, 67, 72, 36])  // C4 E4 G4 C5 C2
        #expect(set.pitchClassMask == 0b0000_1001_0001)
        #expect(set.containsPitchClass(0) && set.containsPitchClass(4) && set.containsPitchClass(7))
        #expect(!set.containsPitchClass(1) && !set.containsPitchClass(12) && !set.containsPitchClass(-1))
    }

    @Test func counterDeltasSeeShortNotesBetweenPolls() {
        var counters = NoteCounters()
        let before = counters
        counters.record(60)
        counters.record(60)
        counters.record(100)
        let struck = counters.struck(since: before)
        #expect(struck.contains(60) && struck.contains(100) && struck.count == 2)
        #expect(counters.struck(since: counters).isEmpty)
        #expect(counters[60] == 2 && counters[100] == 1 && counters[61] == 0)
    }

    @Test func countersWrapWithoutTrapping() {
        var counters = NoteCounters()
        for _ in 0..<300 { counters.record(5) }
        #expect(counters[5] == UInt8(300 % 256))
    }

    @Test func aTrackerStartsNotesOnTheirStepAndEndsThemAfterTheirLength() {
        var tracker = NoteTracker()
        tracker.schedule(step: 4, lengthSteps: 4, note: 60)
        tracker.schedule(step: 6, lengthSteps: 1, note: 64)
        tracker.advance(to: 3.9)
        #expect(tracker.held.isEmpty && tracker.counters[60] == 0)
        tracker.advance(to: 4)
        #expect(tracker.held == NoteSet([60]) && tracker.counters[60] == 1)
        tracker.advance(to: 6.2)
        #expect(tracker.held == NoteSet([60, 64]))
        tracker.advance(to: 7.5)  // the E ended at 7, the C lasts to 8
        #expect(tracker.held == NoteSet([60]))
        tracker.advance(to: 8)
        #expect(tracker.held.isEmpty)
        #expect(tracker.counters[60] == 1 && tracker.counters[64] == 1)
    }

    @Test func aNoteThatStartsAndEndsBetweenTwoAdvancesIsStillCounted() {
        var tracker = NoteTracker()
        tracker.schedule(step: 2, lengthSteps: 1, note: 72)
        tracker.advance(to: 10)
        #expect(tracker.held.isEmpty)
        #expect(tracker.counters[72] == 1)
    }

    @Test func onlyPitchedInstrumentsAreTracked() {
        var tracker = NoteTracker()
        let params = NoteParams(pitch: 60, lengthSteps: 4)
        tracker.schedule(ScheduledNote(step: 0, instrument: .kick, velocity: 1, params: params))
        tracker.schedule(ScheduledNote(step: 0, instrument: .laser, velocity: 1, params: params))
        tracker.schedule(ScheduledNote(step: 0, instrument: .snare, velocity: 1))
        tracker.schedule(ScheduledNote(step: 0, instrument: .sub, velocity: 1))  // no pitch
        tracker.advance(to: 1)
        #expect(tracker.held.isEmpty)
        tracker.schedule(ScheduledNote(step: 1, instrument: .keys, velocity: 1, params: params))
        tracker.schedule(ScheduledNote(step: 1, instrument: .bassGuitar, velocity: 1, params: NoteParams(pitch: 40)))
        tracker.advance(to: 1)
        #expect(tracker.held == NoteSet([60, 40]))
    }

    @Test func resettingReleasesNotesAndKeepsTheCounters() {
        var tracker = NoteTracker()
        tracker.schedule(step: 0, lengthSteps: 8, note: 60)
        tracker.advance(to: 1)
        tracker.reset()
        #expect(tracker.held.isEmpty)
        #expect(tracker.counters[60] == 1)
        tracker.advance(to: 2)
        #expect(tracker.held.isEmpty, "a reset drops the notes still queued")
    }

    @Test func aFullPoolDropsTheOldestNote() {
        var tracker = NoteTracker()
        for i in 0..<(NoteTracker.capacity + 10) { tracker.schedule(step: i, lengthSteps: 1000, note: i % 128) }
        tracker.advance(to: Double(NoteTracker.capacity + 10))
        let started = (0..<NoteSet.noteCount).reduce(0) { $0 + Int(tracker.counters[$1]) }
        #expect(started == NoteTracker.capacity, "the ten oldest notes were dropped before they sounded")
    }

    @Test func aMusicContextCarriesNotesAndAKey() {
        let context = MusicContext(
            heldNotes: NoteSet([57]), noteCounts: NoteCounters(), keyPitchClass: -3, keyIsMinor: true)
        #expect(context.heldNotes.contains(57))
        #expect(context.keyPitchClass == 9, "a key wraps into 0 ... 11")
        #expect(MusicContext().heldNotes.isEmpty && MusicContext().keyPitchClass == nil)
    }
}
