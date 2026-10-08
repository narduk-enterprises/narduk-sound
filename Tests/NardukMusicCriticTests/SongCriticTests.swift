import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicCritic

/// The note half: the lead line, each part, the total and the listener.
@Suite struct SongCriticTests {
    static func note(_ step: Int, _ instrument: Instrument, pitch: Int?, length: Int = 2, voice: Int? = nil)
        -> ScheduledNote
    {
        ScheduledNote(
            step: step, instrument: instrument, velocity: 0.8,
            params: NoteParams(pitch: pitch, lengthSteps: length, voice: voice))
    }

    @Test func onlyMelodicCarriersAreLead() {
        #expect(LeadLine.rank(Self.note(0, .vox, pitch: 60)) == 0)
        #expect(LeadLine.rank(Self.note(0, .vocal, pitch: 60, voice: NoteParams.vocalVoice(.ah, style: .lead))) == 0)
        #expect(LeadLine.rank(Self.note(0, .vocal, pitch: 60, voice: NoteParams.vocalVoice(.ah, style: .choir))) == nil)
        #expect(LeadLine.rank(Self.note(0, .electricGuitar, pitch: 60)) == 1)
        #expect(LeadLine.rank(Self.note(0, .keys, pitch: 60, voice: 0)) == 2)
        #expect(LeadLine.rank(Self.note(0, .keys, pitch: 60, voice: 3)) == nil, "the pad patch is harmony")
        #expect(LeadLine.rank(Self.note(0, .keys, pitch: 60, length: 16)) == nil, "a bar-long note is harmony")
        #expect(LeadLine.rank(Self.note(0, .wobble, pitch: 41)) == 3)
        for instrument in [Instrument.kick, .snare, .sub, .bassGuitar, .strum, .laser, .riser] {
            #expect(LeadLine.rank(Self.note(0, instrument, pitch: 40)) == nil, "\(instrument)")
        }
    }

    @Test func aBarTakesTheBestCarrierAndTheTopOfAChord() {
        let notes = [
            Self.note(0, .wobble, pitch: 41), Self.note(4, .wobble, pitch: 43), Self.note(8, .wobble, pitch: 44),
            Self.note(0, .keys, pitch: 60, voice: 1), Self.note(0, .keys, pitch: 64, voice: 1),
            Self.note(8, .keys, pitch: 67, voice: 1),
        ]
        let line = LeadLine.line(ofBar: notes)
        #expect(line.map(\.pitch) == [64, 67])
        #expect(line.allSatisfy { $0.instrument == .keys })
        // One keys onset is not enough to beat a wobble riff.
        let lone = LeadLine.line(ofBar: Array(notes.prefix(4)))
        #expect(lone.map(\.pitch) == [41, 43, 44])
    }

    @Test func everyDiatonicModeButLydianMapsToSevenDegrees() {
        for mode in HarmonyMode.allCases {
            let degrees = (0..<8).map { LeadLine.degree(62 + mode.semitones($0), tonic: 62 % 12) }
            let consecutive = zip(degrees, degrees.dropFirst()).allSatisfy { $1 - $0 == 1 }
            #expect(consecutive || mode.scale.contains(6), "\(mode): \(degrees)")
        }
        #expect(LeadLine.degree(49, tonic: 2) - LeadLine.degree(50, tonic: 2) == -1)
        #expect(LeadLine.degree(38, tonic: 2) - LeadLine.degree(50, tonic: 2) == -7)
        #expect(LeadLine.degree(1, tonic: 2) == -1)
        #expect(LeadLine.degree(-10, tonic: 2) == -7)
    }

    @Test func theTonicIsReadFromTheNotes() {
        // F# dorian: the semitone 6 map collides under C but not under its own tonic family.
        let pitches = [66, 68, 69, 71, 73, 75, 76]
        let tonic = LeadLine.tonic(of: pitches)
        let degrees = pitches.map { LeadLine.degree($0, tonic: tonic) }
        #expect(Set(degrees).count == 7)
        #expect(zip(degrees, degrees.dropFirst()).allSatisfy { $1 - $0 == 1 })
    }

    @Test func aSingableLineBeatsRandomLeaps() {
        var raw: [String: Double] = [:]
        let singable = [0, 1, 2, 1, 0, 2, 3, 4, 3, 2, 2, 1, 4, 5, 4, 3, 1, 0, 0, 1]
        let leaping = [0, 7, -5, 9, 2, -6, 11, 0, 8, -4, 10, -7, 5, 12, -3, 6]
        #expect(SongCritic.melodyScore(singable, raw: &raw) > SongCritic.melodyScore(leaping, raw: &raw) + 0.3)
        #expect(SongCritic.melodyScore([0, 0, 0, 0, 0, 0, 0, 0, 0], raw: &raw) == 0.05)
        #expect(SongCritic.melodyScore([0, 1], raw: &raw) == 0)
    }

    @Test func repetitionWantsVariationNotCopies() {
        var raw: [String: Double] = [:]
        let copies = Array(repeating: [0, 2, 4, 2], count: 16)
        let echoes = (0..<16).map { bar in bar % 4 == 3 ? [0, 2, 4, 5] : bar % 2 == 0 ? [0, 2, 4, 2] : [0, 3, 1, 2] }
        let unrelated = (0..<16).map { bar in [0, bar % 7 + 3, -(bar % 5) - 3, bar] }
        let echoed = SongCritic.repetitionScore(echoes, raw: &raw)
        #expect(SongCritic.repetitionScore(copies, raw: &raw) < 0.25)
        #expect(echoed > SongCritic.repetitionScore(copies, raw: &raw))
        #expect(echoed > SongCritic.repetitionScore(unrelated, raw: &raw))
    }

    @Test func anArcBuildsAndDrops() {
        var raw: [String: Double] = [:]
        let flat = SongCritic.arcScore(
            sections: Array(repeating: .intro, count: 64), energy: Array(repeating: 0.2, count: 64), raw: &raw)
        var sections: [SongSection] = []
        var energy: [Double] = []
        for bar in 0..<64 {
            let phase = bar % 32
            sections.append(phase < 8 ? .intro : phase < 16 ? .build : phase < 24 ? .drop : .breakdown)
            energy.append(phase < 16 ? Double(phase) / 16 : phase < 24 ? 0.95 : 0.3)
        }
        let built = SongCritic.arcScore(sections: sections, energy: energy, raw: &raw)
        #expect(flat < 0.2)
        #expect(built > 0.8)
    }

    @Test func effectsWantVarietySpreadOut() {
        var raw: [String: Double] = [:]
        let oneKind = (0..<32).map { _ in [Instrument.laser] }
        // Three kinds (the middle of the entropy band), some 4-bar windows busier than others.
        let kinds: [Instrument] = [.laser, .riser, .impact]
        let varied: [[Instrument]] = (0..<32).map { bar in
            let count = (bar / 4) % 2 == 0 ? 1 : 2
            return [Instrument](repeating: kinds[bar % 3], count: count)
        }
        let variedScore = SongCritic.eventScore(varied, raw: &raw)
        let oneKindScore = SongCritic.eventScore(oneKind, raw: &raw)
        #expect(variedScore > oneKindScore + 0.3)
        #expect(SongCritic.eventScore([[], []], raw: &raw) == 0.1)
    }

    @Test func theTotalIsAWeightedGeometricMean() {
        #expect(abs(SongScore.weights.reduce(0) { $0 + $1.weight } - 1) < 1e-12)
        #expect(SongScore.total(melody: 1, repetition: 1, arc: 1, events: 1) == 100)
        // One weak part pulls the total down further than an arithmetic mean would.
        let weak = SongScore.total(melody: 1, repetition: 0.05, arc: 1, events: 1)
        #expect(weak < 100 * (1 - 0.95 * 0.2 / 0.85))
        let score = SongScore(melody: 0.8, repetition: 0.1, arc: 0.9, events: 0.5, seconds: 60, total: 0)
        #expect(score.weakest == "repetition")
    }

    @Test func aSymbolicSongScoresTheSameEveryTime() {
        let settings = SongSettings(genre: .dubstep, seed: 3)
        let first = SongCritic.score(settings: settings, bars: 48)
        let second = SongCritic.score(settings: settings, bars: 48)
        #expect(first == second)
        #expect(first.total > 0 && first.total <= 100)
        #expect(abs(first.seconds - 48 * 16 * settings.secondsPerStep) < 1e-9)
        #expect(first.arc > 0.3, "the energy wave should build and drop: \(first.raw)")
    }

    @Test func theListenerMatchesTheWholeSongScore() {
        let settings = SongSettings(genre: .house, seed: 9)
        let signals = SongCritic.energyWave(bars: 40, settings: settings)
        var conductor = DropConductor(settings: settings)
        var notes: [ScheduledNote] = []
        var sections: [SongSection] = []
        var energy: [Double] = []
        var next = 0
        for step in 0..<(40 * 16) {
            while next < signals.count, signals[next].time < Double(step + 1) * settings.secondsPerStep {
                conductor.ingest(signals[next])
                next += 1
            }
            notes += conductor.advance(throughStep: step)
            if step % 16 == 0 {
                sections.append(conductor.snapshot.section)
                energy.append(conductor.snapshot.energy)
            }
        }
        let whole = SongCritic.score(
            notes: notes, sections: sections, energy: energy, secondsPerStep: settings.secondsPerStep)
        #expect(whole == SongCritic.score(settings: settings, bars: 40))
    }

    @Test func aWindowedListenerForgetsOldBars() {
        var listener = SongListener(window: 8)
        for bar in 0..<40 {
            listener.mark(bar: bar, section: bar < 20 ? .intro : .drop, energy: bar < 20 ? 0.1 : 0.9)
            listener.hear((0..<4).map { Self.note(bar * 16 + $0 * 4, .keys, pitch: 60 + $0) })
        }
        #expect(listener.barCount == 8)
        let score = listener.score()
        #expect(score.raw["dropShare"] == 1, "only the last eight bars (all drop) count")
        #expect(abs(score.seconds - 8 * 16 * listener.secondsPerStep) < 1e-9)
    }
}
