import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct HarmonyTests {
    // MARK: Modes

    @Test func majorModesHaveTheirMajorThirds() {
        #expect(HarmonyMode.major.scale == [0, 2, 4, 5, 7, 9, 11])
        #expect(HarmonyMode.lydian.scale == [0, 2, 4, 6, 7, 9, 11])
        #expect(HarmonyMode.mixolydian.scale == [0, 2, 4, 5, 7, 9, 10])
        #expect(HarmonyMode.allCases.filter(\.isMajorQuality) == [.major, .lydian, .mixolydian])
        #expect(HarmonyMode.major.name == "major")
        #expect(HarmonyMode.minor.name == "minor")
    }

    @Test func degreesCarryOctaves() {
        #expect(HarmonyMode.major.semitones(7) == 12)
        #expect(HarmonyMode.major.semitones(-1) == -1)
        #expect(HarmonyMode.major.semitones(9) == 16)
    }

    // MARK: Voicings (C major, tonic 60)

    private func voiced(_ voicing: ChordVoicing, degree: Int = 0, seventh: Bool = false) -> [Int] {
        Harmony.chordPitches(mode: .major, tonic: 60, degree: degree, voicing: voicing, seventh: seventh)
    }

    @Test func closeStacksThirds() {
        #expect(voiced(.close) == [60, 64, 67])
        #expect(voiced(.close, degree: 5) == [69, 72, 76])  // A minor on the sixth degree
        #expect(voiced(.close, seventh: true) == [60, 64, 67, 71])
    }

    @Test func otherVoicingsRearrangeTheSameNotes() {
        #expect(voiced(.open) == [60, 67, 76])
        #expect(voiced(.drop2) == [52, 60, 67])
        #expect(voiced(.spread) == [48, 60, 67, 76])
        #expect(voiced(.power) == [60, 67, 72])
        #expect(voiced(.shell) == [60, 64, 71])
        #expect(voiced(.drop2, seventh: true) == [55, 60, 64, 71])
    }

    @Test func everyVoicingIsSortedAndStaysInTheMode() {
        for mode in HarmonyMode.allCases {
            for voicing in ChordVoicing.allCases {
                for degree in 0..<7 {
                    let chord = Harmony.chordPitches(
                        mode: mode, tonic: 60, degree: degree, voicing: voicing, seventh: true)
                    #expect(chord == chord.sorted(), "\(mode) \(voicing) degree \(degree)")
                    for pitch in chord where voicing != .power || pitch != chord[2] {
                        #expect(mode.scale.contains(((pitch - 60) % 12 + 12) % 12), "\(mode) \(voicing) \(degree)")
                    }
                }
            }
        }
    }

    // MARK: Strum and comping

    @Test func strumOnsetsFitInHalfAStepEvenForSixStrings() {
        for count in 1...8 {
            let down = StrumDirection.down.delays(count: count)
            let up = StrumDirection.up.delays(count: count)
            #expect(down.count == count && up.count == count)
            #expect(down.allSatisfy { $0 >= 0 && $0 <= StrumDirection.maxSpread + 1e-9 })
            #expect(down == down.sorted())
            #expect(up == up.sorted(by: >))
        }
        #expect(StrumDirection.block.delays(count: 4) == [0, 0, 0, 0])
        #expect(StrumDirection.down.delays(count: 6).last! <= 0.5)
    }

    @Test func aDownStrumPlaysLowToHighAndAnUpStrumHighToLow() {
        let chord = [48, 55, 64]
        let down = CompHit(pos: 0, direction: .down).notes(on: chord)
        let up = CompHit(pos: 0, direction: .up).notes(on: chord)
        #expect(down.map(\.pitch) == chord)
        #expect(down.map(\.delay) == down.map(\.delay).sorted())
        #expect(up.map(\.pitch) == chord)
        #expect(up.first!.delay > up.last!.delay)
    }

    @Test func anArpeggioPlaysOneToneAtATimeAndWraps() {
        let hits = CompingPattern.arpeggio.strokes
        #expect(hits.count == 8)
        let played = hits.flatMap { $0.notes(on: [60, 64, 67]) }.map(\.pitch)
        #expect(played == [60, 64, 67, 60, 67, 64, 67, 60])
    }

    @Test func patternsStayOnTheBarGridAndSustainSpansTwoBars() {
        for pattern in CompingPattern.allCases {
            #expect(pattern.strokes.allSatisfy { (0..<16).contains($0.pos) && $0.length > 0 }, "\(pattern)")
            #expect(!pattern.strokes.isEmpty)
        }
        #expect(CompingPattern.sustain.hits(pos: 0, barInPhrase: 0).count == 1)
        #expect(CompingPattern.sustain.hits(pos: 0, barInPhrase: 1).isEmpty)
        #expect(CompingPattern.folk.hits(pos: 6, barInPhrase: 3).first?.direction == .up)
    }

    // MARK: Families and settings

    @Test func theFirstTenGenresAreElectronicAndRockFolkFunkAreTheBand() {
        let band: [Genre] = [.rock, .folk, .funk]
        #expect(GenreFamily.band.genres == band)
        #expect(GenreFamily.electronic.genres == Genre.allCases.filter { !band.contains($0) })
        #expect(Genre.allCases.filter { $0.family == .electronic }.count == 10)
        #expect(GenreFamily.electronic.shape == FamilyShape())
        #expect(GenreFamily.band.shape.comping != nil)
    }

    @Test func settingsDefaultToTheOldSong() {
        let settings = SongSettings()
        #expect(settings.family == .electronic)
        #expect(settings.mode == nil && settings.effectiveVoicing == nil && settings.effectiveComping == nil)
    }

    @Test func aFamilySuppliesShapeDefaultsThatSettingsOverride() {
        var settings = SongSettings(family: .band)
        #expect(settings.effectiveComping == GenreFamily.band.shape.comping)
        settings.comping = .stabs
        settings.voicing = .shell
        #expect(settings.effectiveComping == .stabs && settings.effectiveVoicing == .shell)
    }

    @Test func settingsSavedBeforeTheHarmonyFieldsStillDecode() throws {
        let old = """
            {"bpm":128,"genre":"house","keyRoot":62,"stepsPerBar":16,"barsPerPhrase":8,"seed":42}
            """
        let settings = try JSONDecoder().decode(SongSettings.self, from: Data(old.utf8))
        #expect(settings == SongSettings(bpm: 128, genre: .house, keyRoot: 62, seed: 42))
    }

    @Test func settingsRoundTripWithHarmony() throws {
        let settings = SongSettings(
            genre: .chill, family: .band, mode: .major, voicing: .drop2, comping: .folk)
        let decoded = try JSONDecoder().decode(SongSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

/// A track written in a major mode with voiced chords, and the guarantee that leaving the new settings unset changes
/// nothing about the song.
@Suite struct MajorSongTests {
    static let steps = 8 * 16 * 6

    /// Settings for a genre at its own tempo (`SongSettings(genre:)` alone does the same, but only without the rest).
    static func make(
        genre: Genre, family: GenreFamily = .electronic, mode: HarmonyMode? = nil, voicing: ChordVoicing? = nil,
        comping: CompingPattern? = nil
    ) -> SongSettings {
        SongSettings(
            bpm: genre.defaultBPM, genre: genre, family: family, mode: mode, voicing: voicing, comping: comping)
    }

    static func record(_ settings: SongSettings) -> DropConductorTests.Recording {
        var conductor = DropConductor(settings: settings)
        return DropConductorTests.play(&conductor, steps: steps, batch: DropConductorTests.rampThenSettle)
    }

    @Test func aPinnedMajorModeWritesMajorTracksInKey() {
        for genre in Genre.allCases {
            let recording = Self.record(Self.make(genre: genre, mode: .major))
            #expect(recording.tracks.allSatisfy { $0.mode == .ionian }, "\(genre)")
            #expect(recording.tracks.first!.keyName.hasSuffix("major"), "\(genre)")
            let pitched = recording.notes.filter { $0.params.pitch != nil && $0.instrument != .riser }
            #expect(!pitched.isEmpty, "\(genre)")
            #expect(pitched.allSatisfy(recording.inKey), "\(genre): out-of-key note")
        }
    }

    @Test func majorChordsAreMajorOrMinorTriadsOnTheScale() {
        let recording = Self.record(
            Self.make(genre: .house, mode: .major, voicing: .close, comping: .stabs))
        let without = Self.record(Self.make(genre: .house, mode: .major, voicing: .close))
        let stabs = recording.notes.filter { !without.notes.contains($0) }
        #expect(!stabs.isEmpty)
        // Stabs at one step land together as a chord: every pitch of it sits in the major scale.
        #expect(stabs.allSatisfy(recording.inKey))
        let byStep = Dictionary(grouping: stabs, by: \.step)
        #expect(byStep.values.contains { $0.count == 3 })
    }

    @Test func aStrumStaggersItsStringsWithinAStep() {
        let recording = Self.record(Self.make(genre: .chill, mode: .major, voicing: .drop2, comping: .strum))
        let without = Self.record(Self.make(genre: .chill, mode: .major, voicing: .drop2))
        let strums = recording.notes.filter { !without.notes.contains($0) }
        #expect(!strums.isEmpty)
        #expect(strums.allSatisfy { $0.instrument == .keys })
        for (_, chord) in Dictionary(grouping: strums, by: \.step) where chord.count > 1 {
            let delays = chord.map { $0.params.delay ?? 0 }
            #expect(delays.allSatisfy { $0 >= 0 && $0 <= 0.5 })
            #expect(Set(delays).count == chord.count, "every string sounds at its own time")
        }
    }

    @Test func unsetHarmonyChangesNothing() {
        let plain = Self.record(Self.make(genre: .dubstep))
        let explicit = Self.record(
            Self.make(genre: .dubstep, family: .electronic, mode: nil, voicing: nil, comping: nil))
        #expect(plain.notes == explicit.notes)
        #expect(plain.tracks.contains { !$0.mode.isMajorQuality })
    }

    @Test func pinningAMinorModeKeepsEverythingButTheModeTheSame() {
        let free = Self.record(Self.make(genre: .trap))
        let pinned = Self.record(Self.make(genre: .trap, mode: .minor))
        #expect(pinned.tracks.allSatisfy { $0.mode == .aeolian })
        // The same seed writes the same hooks, bass patches and drums; only the scale under them moved.
        #expect(zip(free.tracks, pinned.tracks).allSatisfy { $0.hook == $1.hook && $0.voice == $1.voice })
    }

    @Test func theSameSettingsWriteTheSameHouseSong() {
        #expect(Self.record(Self.make(genre: .house)).notes == Self.record(Self.make(genre: .house)).notes)
    }

    @Test func aCompingLayerOnlyAddsKeysNotes() {
        let plain = Self.record(Self.make(genre: .house))
        let comped = Self.record(Self.make(genre: .house, comping: .folk))
        #expect(comped.notes.count > plain.notes.count)
        let extra = comped.notes.filter { !plain.notes.contains($0) }
        #expect(extra.allSatisfy { $0.instrument == .keys })
        #expect(comped.snapshots.contains { $0.legend.contains { $0.hasPrefix("chords") } })
    }
}
