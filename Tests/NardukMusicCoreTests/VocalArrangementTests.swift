import Testing

@testable import NardukMusicCore

/// Vocals and cuts in an arrangement (narduk-libs#1641) appear only behind `SongSettings.variety`.
@Suite struct VocalArrangementTests {
    static let sung: Set<Instrument> = [.vocal, .vocalChop, .cut]

    static func play(_ genre: Genre, variety: Double, seed: UInt64, bars: Int = 96) -> (
        notes: [ScheduledNote], track: Track
    ) {
        var conductor = DropConductor(settings: SongSettings.varied(genre: genre, seed: seed, variety: variety))
        var notes: [ScheduledNote] = []
        for step in 0..<(bars * 16) {
            let phase = (step / 16) % 32
            conductor.ingest(MusicSignal(level: phase < 6 ? 0.1 : (phase < 12 ? 0.6 : 0.95), levelLabel: "CPU"))
            notes += conductor.advance(throughStep: step)
        }
        return (notes, conductor.track)
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
