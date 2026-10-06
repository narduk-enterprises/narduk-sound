import Testing

@testable import NardukMusicCore

@Suite struct MusicContextTests {
    @Test func everyInstrumentHasADistinctLaneBelowTheLaneCount() {
        let lanes = Instrument.allCases.map(\.index)
        #expect(Set(lanes).count == lanes.count)
        #expect(lanes.allSatisfy { $0 >= 0 && $0 < HitCounters.laneCount })
        // Dense: lanes are exactly 0 ..< count, so nothing is skipped or renumbered.
        #expect(Set(lanes) == Set(0..<lanes.count))
    }

    @Test func deltaCountsEveryHitEvenWhenFramesAreSkipped() {
        var counters = HitCounters()
        let seen = counters
        counters.record(.kick)
        counters.record(.kick)
        counters.record(.snare)
        let delta = counters.delta(since: seen)
        #expect(delta[.kick] == 2)
        #expect(delta[.snare] == 1)
        #expect(delta[.hat] == 0)
    }

    @Test func deltaSurvivesWrapAround() {
        var counters = HitCounters()
        counters[.kick] = UInt32.max
        let seen = counters
        counters.record(.kick)
        counters.record(.kick)
        #expect(counters[.kick] == 1)
        #expect(counters.delta(since: seen)[.kick] == 2)
    }
}
