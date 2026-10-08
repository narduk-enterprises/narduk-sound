import Testing

@testable import NardukMusicCore

/// Vocals and cuts in an arrangement (narduk-libs#1641) appear only behind `SongSettings.variety`.
@Suite struct VocalArrangementTests {
    static let sung: Set<Instrument> = [.vocal, .vocalChop, .cut]

    static func play(_ genre: Genre, variety: Double, seed: UInt64, bars: Int = 96) -> (
        notes: [ScheduledNote], track: Track
    ) {
        var settings = SongSettings.varied(genre: genre, seed: seed, variety: variety)
        settings.vocals = true
        var conductor = DropConductor(settings: settings)
        var notes: [ScheduledNote] = []
        for step in 0..<(bars * 16) {
            let phase = (step / 16) % 32
            conductor.ingest(MusicSignal(level: phase < 6 ? 0.1 : (phase < 12 ? 0.6 : 0.95), levelLabel: "CPU"))
            notes += conductor.advance(throughStep: step)
        }
        return (notes, conductor.track)
    }

    /// Voices are off unless a song asks (first blind test, 2026-10-07), and dropping them leaves every other part
    /// exactly as it was.
    @Test func voicesAreOffByDefaultAndTheRestIsUntouched() {
        #expect(!SongSettings().vocals)
        for genre in [Genre.house, .tropicalHouse, .chill, .dubstep] {
            var off = DropConductor(settings: SongSettings.varied(genre: genre, seed: 3, variety: 1))
            var settings = SongSettings.varied(genre: genre, seed: 3, variety: 1)
            settings.vocals = true
            var on = DropConductor(settings: settings)
            var quiet: [ScheduledNote] = []
            var sung: [ScheduledNote] = []
            for step in 0..<(64 * 16) {
                let signal = MusicSignal(level: (step / 16) % 32 < 12 ? 0.3 : 0.95, levelLabel: "CPU")
                off.ingest(signal)
                on.ingest(signal)
                quiet += off.advance(throughStep: step)
                sung += on.advance(throughStep: step)
            }
            #expect(quiet.allSatisfy { !$0.instrument.isVoice }, "\(genre)")
            #expect(sung.contains { $0.instrument.isVoice }, "\(genre)")
            #expect(quiet == sung.filter { !$0.instrument.isVoice }, "\(genre)")
        }
    }

    @Test func noVarietyMeansNoVocalsAndNoCuts() {
        for genre in Genre.allCases {
            let (notes, track) = Self.play(genre, variety: 0, seed: 11)
            #expect(track.vocals == nil, "\(genre)")
            #expect(notes.allSatisfy { !Self.sung.contains($0.instrument) }, "\(genre)")
        }
    }

    @Test func varietyAddsVocalsAndCutsWhereTheyFit() {
        var instruments: [Genre: Set<Instrument>] = [:]
        for genre in [Genre.chill, .house, .synthwave, .dubstep, .trap, .ukGarage] {
            for seed: UInt64 in 1...6 {
                let (notes, track) = Self.play(genre, variety: 1, seed: seed)
                #expect(track.vocals?.isEmpty != true)
                instruments[genre, default: []].formUnion(notes.map(\.instrument).filter(Self.sung.contains))
            }
        }
        for genre in [Genre.chill, .house, .synthwave] {
            #expect(instruments[genre]?.contains(.vocal) == true, "\(genre)")
        }
        for genre in [Genre.dubstep, .trap, .ukGarage, .house] {
            #expect(instruments[genre]?.contains(.vocalChop) == true, "\(genre)")
        }
        #expect(instruments.values.contains { $0.contains(.cut) })
    }

    @Test func aVocalPlanIsDeterministic() {
        let a = Self.play(.house, variety: 0.7, seed: 5)
        let b = Self.play(.house, variety: 0.7, seed: 5)
        #expect(a.notes == b.notes && a.track.vocals == b.track.vocals)
    }
}
