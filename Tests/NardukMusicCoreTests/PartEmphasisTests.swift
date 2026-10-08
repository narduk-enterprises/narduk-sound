import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct PartEmphasisTests {
    /// The level each phrase of the test set rides: a quiet intro, builds, drops, breakdowns, and back.
    static let phraseLevels: [Double] = [
        0.2, 0.2, 0.9, 0.9, 0.9, 0.9, 0.3, 0.3, 0.95, 0.95, 0.95, 0.5, 0.1, 0.1, 0.9, 0.9,
    ]

    /// Plays `bars` bars of `genre` at `emphasis` (nil leaves the conductor untouched), with a level curve and a few cues.
    static func record(
        _ genre: Genre, bars: Int = 128, seed: UInt64 = 7, vocals: Bool = false,
        emphasis: PartEmphasis? = nil
    )
        -> [ScheduledNote]
    {
        var conductor = DropConductor(settings: SongSettings(genre: genre, seed: seed, variety: 1, vocals: vocals))
        if let emphasis { conductor.setPartEmphasis(emphasis) }
        let perBar = conductor.settings.stepsPerBar
        let perPhrase = conductor.settings.stepsPerPhrase
        var notes: [ScheduledNote] = []
        for step in 0..<(bars * perBar) {
            var cues: [MusicCue] = []
            if step % 5 == 0 { cues.append(.tick("t\(step % 3)")) }
            if step % 13 == 0 { cues.append(.voice("v\(step % 4)")) }
            if step % 29 == 0 { cues.append(.sparkle("s")) }
            let level = phraseLevels[(step / perPhrase) % phraseLevels.count]
            conductor.ingest(MusicSignal(level: level, cues: cues))
            notes += conductor.advance(throughStep: step)
        }
        return notes
    }

    static func fingerprint(_ notes: [ScheduledNote]) -> String {
        String(format: "0x%016llx", StableHash.fnv1a(notes.map { String(describing: $0) }.joined(separator: "\n")))
    }

    /// The note stream of `record(genre)` on origin/main before part emphasis existed (voices off, as by default), on
    /// macOS. Neutral must still write it exactly.
    static let neutralGoldens: [Genre: String] = [
        .dubstep: "0x9916f4183bebb48b", .riddim: "0xc68239ac6333b951", .drumAndBass: "0xba3fabc60845827f",
        .trap: "0xb23889a93f5b1b3b", .house: "0x38e48a6b232994e1", .chill: "0x283498fb3e5b5b23",
        .techno: "0xb278281fd5921e9a", .ukGarage: "0x28002186d5f7e0b8", .synthwave: "0x1e41cc898db0be82",
        .lofi: "0xc82695463ad30cad", .rock: "0xebc76f311d7de20e", .folk: "0xdc75ccf704366e43",
        .funk: "0x0e7614df20854a10", .tropicalHouse: "0x809f86d081824ea9",
    ]

    static func count(_ notes: [ScheduledNote], _ part: PartEmphasis.Part) -> Int {
        notes.filter { PartEmphasis.Part($0.instrument) == part }.count
    }

    @Test(arguments: Genre.allCases)
    func neutralWritesTodaysSong(genre: Genre) {
        let untouched = Self.record(genre)
        #expect(Self.record(genre, emphasis: .neutral) == untouched)
        #expect(
            Self.record(genre, emphasis: PartEmphasis(drums: 1, bass: 1, keys: 1, guitar: 1, vocals: 1, fx: 1))
                == untouched)
        #if os(macOS)
            #expect(Self.fingerprint(untouched) == Self.neutralGoldens[genre], "\(genre)")
        #endif
    }

    @Test(arguments: [Genre.dubstep, .drumAndBass, .house, .rock, .chill, .trap])
    func moreDrumsWritesMoreDrumNotes(genre: Genre) {
        let bars = 128
        func perBar(_ weight: Double) -> Double {
            Double(Self.count(Self.record(genre, bars: bars, emphasis: PartEmphasis(drums: weight)), .drums))
                / Double(bars)
        }
        let low = perBar(0.5)
        let mid = perBar(1)
        let high = perBar(2)
        #expect(high > mid && mid > low, "\(genre): \(low) / \(mid) / \(high) drum notes per bar")
    }

    @Test(arguments: Genre.allCases)
    func vocalsAtZeroWriteNoVocalNotes(genre: Genre) {
        let notes = Self.record(genre, vocals: true, emphasis: PartEmphasis(vocals: 0))
        #expect(Self.count(notes, .vocals) == 0)
    }

    @Test func vocalsAreWrittenAtOneSoTheZeroTestMeansSomething() {
        let total = [Genre.chill, .tropicalHouse, .dubstep].map { Self.count(Self.record($0, vocals: true), .vocals) }
        #expect(total.allSatisfy { $0 > 0 }, "\(total)")
    }

    @Test(arguments: PartEmphasis.Part.allCases)
    func aPartAtZeroIsNeverWritten(part: PartEmphasis.Part) {
        var emphasis = PartEmphasis.neutral
        emphasis[part] = 0
        for genre in [Genre.rock, .house, .chill] {
            #expect(
                Self.count(Self.record(genre, bars: 64, vocals: true, emphasis: emphasis), part) == 0,
                "\(genre) \(part)")
        }
    }

    @Test func aGenreWithoutGuitarStaysGuitarFree() {
        let full = PartEmphasis(drums: 2, bass: 2, keys: 2, guitar: 2, vocals: 2, fx: 2)
        for genre in Genre.allCases where genre.family != .band {
            #expect(Self.count(Self.record(genre, bars: 64, emphasis: full), .guitar) == 0, "\(genre)")
        }
    }

    @Test func eachPartFollowsItsWeight() {
        for (part, genre) in [
            (PartEmphasis.Part.bass, Genre.house), (.keys, .house), (.guitar, .rock), (.vocals, .chill),
        ] {
            var down = PartEmphasis.neutral
            down[part] = 0.5
            var up = PartEmphasis.neutral
            up[part] = 2
            let voices = part == .vocals
            let low = Self.count(Self.record(genre, vocals: voices, emphasis: down), part)
            let mid = Self.count(Self.record(genre, vocals: voices), part)
            let high = Self.count(Self.record(genre, vocals: voices, emphasis: up), part)
            #expect(high > mid && mid > low, "\(part) in \(genre): \(low) / \(mid) / \(high)")
        }
    }

    @Test func aChangeLandsOnThePhraseLine() {
        let settings = SongSettings(genre: .house, seed: 3, variety: 1)
        var plain = DropConductor(settings: settings)
        var steered = DropConductor(settings: settings)
        let phrase = settings.stepsPerPhrase
        var before: [ScheduledNote] = []
        var after: [ScheduledNote] = []
        for step in 0..<(3 * phrase) {
            plain.ingest(MusicSignal(level: 0.9))
            steered.ingest(MusicSignal(level: 0.9))
            if step == phrase + 5 { steered.setPartEmphasis(PartEmphasis(drums: 0)) }
            let a = plain.advance(throughStep: step)
            let b = steered.advance(throughStep: step)
            if step < 2 * phrase { #expect(a == b, "step \(step) changed before the phrase line") }
            before += a
            after += b
        }
        #expect(steered.partEmphasis == PartEmphasis(drums: 0))
        #expect(steered.pendingPartEmphasis == nil)
        #expect(Self.count(after.filter { $0.step >= 2 * phrase }, .drums) == 0)
        #expect(Self.count(before.filter { $0.step >= 2 * phrase }, .drums) > 0)
    }

    @Test func weightsClampAndDecodeMissingPartsAsOne() throws {
        let wild = PartEmphasis(drums: 5, bass: -1, keys: .nan)
        #expect(wild.drums == 2 && wild.bass == 0 && wild.keys == 1)
        var steered = PartEmphasis.neutral
        steered[.fx] = 9
        #expect(steered.fx == 2)
        let decoded = try JSONDecoder().decode(PartEmphasis.self, from: Data(#"{"drums":1.5}"#.utf8))
        #expect(decoded == PartEmphasis(drums: 1.5))
        let round = try JSONDecoder().decode(PartEmphasis.self, from: JSONEncoder().encode(wild))
        #expect(round == wild)
        #expect(PartEmphasis.neutral.isNeutral && !wild.isNeutral)
    }
}
