import Foundation
import Testing

@testable import NardukMusicCore

/// Long sets must not repeat themselves (the Forever Loop variety audit): the phrase-end fills come from the track and
/// the genre bank, not a kick drop every time, and the tempo walks across the genre's range one smooth hand-over at a
/// time instead of sitting near the default.
@Suite struct SetSamenessTests {
    /// What a level-only source (no flow, no character hint) hears over a long set, read at every phrase end.
    struct Set {
        /// The fill that ended each drop phrase.
        var dropFills: [Fill] = []
        /// Each track's tempo, in order.
        var tempos: [Double] = []
    }

    static func play(_ genre: Genre, seed: UInt64, minutes: Double) -> Set {
        var settings = SongSettings(genre: genre)
        settings.seed = seed
        var c = DropConductor(settings: settings)
        let phrase = c.settings.stepsPerPhrase
        var set = Set()
        var seconds = 0.0
        var end = -1
        var lastTrack = 0
        while seconds < minutes * 60 {
            // A slow energy swell, so the set builds, drops and breathes.
            let level = 0.55 + 0.4 * sin(seconds / 40)
            c.ingest(MusicSignal(time: seconds, level: level))
            end += phrase
            _ = c.advance(throughStep: end)
            seconds += Double(phrase) * c.settings.secondsPerStep
            if c.snapshot.section.isDrop { set.dropFills.append(c.plan.fill) }
            if c.track.number != lastTrack {
                lastTrack = c.track.number
                set.tempos.append(c.track.bpm)
            }
        }
        return set
    }

    @Test(arguments: [Genre.dubstep, .trap, .funk])
    func dropPhrasesEndOnTheTracksOwnFills(genre: Genre) {
        let set = Self.play(genre, seed: 0x5EED, minutes: 30)
        let kinds = Swift.Set(set.dropFills)
        let kickDrops = Double(set.dropFills.filter { $0 == .kickDrop }.count) / Double(max(1, set.dropFills.count))
        #expect(set.dropFills.count >= 20, "\(genre): \(set.dropFills.count) drop phrases")
        #expect(kinds.count >= 3, "\(genre): fills \(kinds.map { "\($0)" }.sorted())")
        #expect(kickDrops < 0.6, "\(genre): kick drop ends \(Int(kickDrops * 100))% of drop phrases")
    }

    @Test func onlyAMeasuredLullCutsTheKick() {
        var track = Track()
        track.fills = [.snareRoll, .tripletRoll]
        let unmeasured = PhrasePlanner.plan(track: track, section: .drop, phraseInTrack: 1, live: .idle, roll: 1)
        #expect(unmeasured.fill == .tripletRoll)
        let lull = PhrasePlanner.plan(track: track, section: .drop, phraseInTrack: 1, live: .idle, lull: true, roll: 1)
        #expect(lull.fill == .kickDrop)

        var flow = FlowCharacterizer()
        for _ in 0..<100 { flow.observe(bytesIn: 0, bytesOut: 0, connections: 0, errors: 0, seconds: 0.1) }
        #expect(flow.current == .idle && !flow.measuredLull, "no flow is not a lull")
        for _ in 0..<100 { flow.observe(bytesIn: 300, bytesOut: 100, connections: 0, errors: 0, seconds: 0.1) }
        #expect(flow.current == .idle && flow.measuredLull, "quiet flow is")
        flow.hint = .idle
        #expect(!flow.measuredLull, "a pinned idle is not measured")
    }

    static let seeds: [UInt64] = (1...12).map { $0 &* 0x1F3D_5B79 &+ 0x5EED }

    @Test(arguments: Genre.allCases)
    func tempoWalksTheWholeRangeSmoothly(genre: Genre) {
        let range = genre.tempoRange
        let span = range.upperBound - range.lowerBound
        var heard = Swift.Set<Double>()
        for seed in Self.seeds {
            let tempos = Self.play(genre, seed: seed, minutes: 60).tempos
            #expect(tempos.count >= 10, "\(genre) seed \(seed): \(tempos.count) tracks")
            for (a, b) in zip(tempos, tempos.dropFirst()) {
                #expect(abs(b - a) >= TrackGenerator.minTempoStep, "\(genre): \(a) → \(b) is no new tempo")
                #expect(abs(b - a) <= a * TrackGenerator.maxTempoStep, "\(genre): \(a) → \(b) jumps")
            }
            heard.formUnion(tempos)
        }
        let used = ((heard.max() ?? 0) - (heard.min() ?? 0)) / span
        #expect(used >= 0.6, "\(genre): \(heard.sorted()) of \(range)")
        #expect(heard.allSatisfy { range.contains($0) }, "\(genre): \(heard.sorted()) of \(range)")
    }

    @Test func theConductorWalksTheTempoBetweenTracks() {
        let set = Self.play(.dubstep, seed: 0x5EED, minutes: 20)
        let range = Genre.dubstep.tempoRange
        #expect(set.tempos.count >= 6, "\(set.tempos)")
        #expect(set.tempos.allSatisfy { range.contains($0) }, "\(set.tempos)")
        for (a, b) in zip(set.tempos, set.tempos.dropFirst()) {
            #expect(abs(b - a) >= 3 && abs(b - a) <= a * 0.08, "\(a) → \(b)")
        }
        #expect(Swift.Set(set.tempos).count >= 4, "\(set.tempos)")
    }
}
