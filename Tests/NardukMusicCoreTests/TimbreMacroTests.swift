import Foundation
import Testing

@testable import NardukMusicCore

/// A track's timbre macro (narduk-sound#33): seeded per track, inside its genre's range, and carried on every note.
@Suite struct TimbreMacroTests {
    static func track(_ genre: Genre, seed: UInt64, variety: Double = 1) -> Track {
        TrackGenerator.make(
            number: 1, genre: genre, character: .steady, sessionSeed: seed, bpm: genre.defaultBPM, topApp: nil,
            previous: nil, variety: variety)
    }

    /// Over 20 seeds every axis of every genre stays inside the genre's bounds and spreads across most of them.
    @Test(arguments: Genre.allCases)
    func macroSpreadsAcrossTheGenresRange(_ genre: Genre) throws {
        let bounds = TimbreMacro.bounds(genre)
        var axes = [[Double]](repeating: [], count: 6)
        for seed in UInt64(1)...20 {
            let macro = try #require(Self.track(genre, seed: seed &* 7_919).timbre)
            for (index, value) in macro.values.enumerated() { axes[index].append(value) }
        }
        for (index, values) in axes.enumerated() {
            let low = values.min() ?? 0
            let high = values.max() ?? 0
            let bound = bounds[index]
            let slack = 1.0 / 127
            #expect(low >= bound.lowerBound - slack && high <= bound.upperBound + slack, "axis \(index) of \(genre)")
            let width = bound.upperBound - bound.lowerBound
            #expect(high - low >= 0.5 * width, "axis \(index) of \(genre) spans \(high - low) of \(width)")
        }
    }

    /// The axes move together, as a designed patch's do: a slow attack comes with a long decay.
    @Test(arguments: Genre.allCases)
    func attackAndDecayAreCorrelated(_ genre: Genre) throws {
        var attack: [Double] = []
        var decay: [Double] = []
        for seed in UInt64(1)...20 {
            let macro = try #require(Self.track(genre, seed: seed &* 104_729).timbre)
            attack.append(macro.attack)
            decay.append(macro.decay)
        }
        func mean(_ x: [Double]) -> Double { x.reduce(0, +) / Double(x.count) }
        let ma = mean(attack)
        let md = mean(decay)
        let cov = zip(attack, decay).map { ($0 - ma) * ($1 - md) }.reduce(0, +)
        let va = attack.map { ($0 - ma) * ($0 - ma) }.reduce(0, +)
        let vd = decay.map { ($0 - md) * ($0 - md) }.reduce(0, +)
        #expect(cov / (va * vd).squareRoot() > 0.5)
    }

    /// The next track of a genre takes a different character from the one before it.
    @Test func consecutiveTracksChangeCharacter() throws {
        var previous: Track?
        for number in 1...12 {
            let track = TrackGenerator.make(
                number: number, genre: .techno, character: .steady, sessionSeed: 77, bpm: 130, topApp: nil,
                previous: previous, variety: 1)
            let character = try #require(track.timbreCharacter)
            if let before = previous?.timbreCharacter { #expect(character != before) }
            previous = track
        }
    }

    @Test func gentleGenresGetNarrowRanges() {
        for gentle in [Genre.tropicalHouse, .lofi, .chill] {
            for hard in [Genre.dubstep, .riddim, .drumAndBass, .techno] {
                #expect(TimbreMacro.range(gentle) < TimbreMacro.range(hard) / 2)
            }
        }
    }

    @Test func varietyZeroKeepsTheStandardSound() {
        #expect(Self.track(.house, seed: 3, variety: 0).timbre == nil)
        #expect(Self.track(.house, seed: 3, variety: 0.5).timbre != nil)
    }

    @Test func theSameSeedWritesTheSameMacro() {
        #expect(Self.track(.dubstep, seed: 11).timbre == Self.track(.dubstep, seed: 11).timbre)
        #expect(Self.track(.dubstep, seed: 11).timbre != Self.track(.dubstep, seed: 12).timbre)
    }

    @Test func packingRoundTrips() throws {
        let macro = TimbreMacro(
            detune: -1, cutoff: 0.5, attack: 0, decay: 0.25, width: -0.3, drive: 1, variationSeed: 201)
        #expect(TimbreMacro(packed: macro.packed) == macro)
        #expect(TimbreMacro(packed: TimbreMacro().packed) == TimbreMacro())
        #expect(TimbreMacro(packed: 0) == nil)
    }

    /// The conductor stamps the track's macro on every note it writes, and none at variety 0.
    @Test func theConductorCarriesTheMacroOnEveryNote() {
        var varied = DropConductor(settings: SongSettings(genre: .house, seed: 9, variety: 1))
        let notes = varied.advance(throughStep: 16 * 16)
        #expect(!notes.isEmpty)
        #expect(notes.allSatisfy { $0.params.timbre.flatMap(TimbreMacro.init(packed:)) != nil })
        var plain = DropConductor(settings: SongSettings(genre: .house, seed: 9, variety: 0))
        #expect(plain.advance(throughStep: 16 * 16).allSatisfy { $0.params.timbre == nil })
    }
}
