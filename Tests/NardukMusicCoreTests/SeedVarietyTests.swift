import Foundation
import Testing

@testable import NardukMusicCore

/// A new seed should be a different song, not a reshuffle (narduk-libs#1617). Each test writes tracks for many
/// seeds of one genre and measures how far apart they are on the features a listener hears.
@Suite struct SeedVarietyTests {
    static let seeds: [UInt64] = (1...16).map { $0 &* 0x1F3D_5B79 &+ 0x5EED }

    static func tracks(_ genre: Genre, variety: Double) -> [Track] {
        seeds.map { seed in
            let settings = SongSettings.varied(genre: genre, seed: seed, variety: variety)
            return TrackGenerator.make(
                number: 1, genre: genre, character: .steady, sessionSeed: seed, bpm: variety > 0 ? settings.bpm : 140,
                topApp: nil, previous: nil, variety: variety)
        }
    }

    /// 0 (the same song) ... 1: the mean of key, mode, progression, hook, tempo, drum pattern and timbre differences
    /// (timbre counts double its raw spread, since its parameters rarely span their whole range).
    static func distance(_ a: Track, _ b: Track, genre: Genre) -> Double {
        let range = genre.tempoRange
        let tempo = min(1, abs(a.bpm - b.bpm) / max(1, range.upperBound - range.lowerBound))
        let ka = a.kit(drop2: false)
        let kb = b.kit(drop2: false)
        func jaccard(_ x: [Int], _ y: [Int]) -> Double {
            let union = Set(x).union(y).count
            return union == 0 ? 0 : 1 - Double(Set(x).intersection(y).count) / Double(union)
        }
        let drums = (jaccard(ka.kicksA, kb.kicksA) + jaccard(ka.kicksB, kb.kicksB) + jaccard(ka.ghosts, kb.ghosts)) / 3
        let timbre = [
            abs(a.kickTune - b.kickTune), abs(a.snareTune - b.snareTune), abs(a.hatTune - b.hatTune),
            abs(a.formant - b.formant), abs(a.drive - b.drive),
        ]
        let features: [Double] = [
            a.keyRoot % 12 == b.keyRoot % 12 ? 0 : 1,
            a.mode == b.mode ? 0 : 1,
            a.progression == b.progression ? 0 : 1,
            a.hook.distance(to: b.hook),
            tempo,
            drums,
            timbre.reduce(0, +) / Double(timbre.count) * 2,
        ]
        return features.reduce(0, +) / Double(features.count)
    }

    static func meanDistance(_ tracks: [Track], genre: Genre) -> Double {
        var total = 0.0
        var pairs = 0
        for i in tracks.indices {
            for j in tracks.indices where j > i {
                total += distance(tracks[i], tracks[j], genre: genre)
                pairs += 1
            }
        }
        return total / Double(pairs)
    }

    /// The stated threshold: seeds of a genre sit at least this far apart on average (measured 0.61 ... 0.69 across the genres; the
    /// banked songs sit at 0.46 ... 0.54), and well past where variety 0 leaves them.
    static let threshold = 0.60
    static let gain = 0.12

    @Test(arguments: Genre.allCases) func seedsSoundDifferent(genre: Genre) {
        let banked = Self.meanDistance(Self.tracks(genre, variety: 0), genre: genre)
        let varied = Self.meanDistance(Self.tracks(genre, variety: 0.75), genre: genre)
        #expect(varied >= Self.threshold, "\(genre.rawValue): mean seed distance \(varied)")
        #expect(varied >= banked + Self.gain, "\(genre.rawValue): \(varied) against banked \(banked)")
    }

    @Test(arguments: Genre.allCases) func progressionsAreNewAndWellFormed(genre: Genre) {
        let banked = Set(Self.tracks(genre, variety: 0).map(\.progression))
        let varied = Self.tracks(genre, variety: 1)
        for track in varied {
            #expect(track.progression.count == 8)
            #expect(track.progression.allSatisfy { (0...6).contains($0) })
        }
        let distinct = Set(varied.map(\.progression))
        #expect(distinct.count >= 10, "\(genre.rawValue): \(distinct.count) distinct progressions in 16 seeds")
        #expect(distinct.count > banked.count, "\(genre.rawValue): \(distinct.count) against \(banked.count) banked")
    }

    @Test(arguments: Genre.allCases) func varietyZeroIsTheBankedSong(genre: Genre) {
        for seed in Self.seeds.prefix(4) {
            let plain = TrackGenerator.make(
                number: 2, genre: genre, character: .busy, sessionSeed: seed, bpm: 120, topApp: nil, previous: nil)
            let zero = TrackGenerator.make(
                number: 2, genre: genre, character: .busy, sessionSeed: seed, bpm: 120, topApp: nil, previous: nil,
                variety: 0)
            #expect(plain == zero)
        }
    }

    @Test func temposStayInsideTheGenre() {
        for genre in Genre.allCases {
            for seed in Self.seeds {
                let bpm = SongSettings.varied(genre: genre, seed: seed).bpm
                #expect(genre.tempoRange.contains(bpm), "\(genre.rawValue) \(bpm)")
            }
            let tempos = Set(Self.seeds.map { SongSettings.varied(genre: genre, seed: $0).bpm })
            #expect(tempos.count >= 5, "\(genre.rawValue) \(tempos.count) distinct tempos")
        }
    }

    @Test func settingsFromBeforeVarietyDecodeAsZero() throws {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(SongSettings(genre: .house))) as? [String: Any])
        #expect(json.removeValue(forKey: "variety") != nil)
        let old = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(SongSettings.self, from: old).variety == 0)
        let round = try JSONDecoder().decode(
            SongSettings.self, from: JSONEncoder().encode(SongSettings(variety: 0.4)))
        #expect(round.variety == 0.4)
    }

    @Test func halfTimeIsRareAndOnlyWhereTheBackbeatHasIt() {
        for genre in Genre.allCases {
            let halves = Self.tracks(genre, variety: 1).filter(\.halfTime).count
            if Variety.halfTimes(genre) {
                #expect((1...10).contains(halves), "\(genre.rawValue): \(halves) half-time songs in 16")
            } else {
                #expect(halves == 0, "\(genre.rawValue)")
            }
        }
    }
}
