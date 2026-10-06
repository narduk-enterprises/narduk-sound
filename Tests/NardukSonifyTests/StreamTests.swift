import Foundation
import NardukMusicCore
import Testing

@testable import NardukSonify

/// A deterministic stream of numbers: no real data, the same on every run.
struct Lcg {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}

@Suite struct StreamSonifierTests {
    static let schema = StreamSchema(["size", "price"])

    @Test func streamIsBoundedAndCausal() {
        var sonifier = StreamSonifier(schema: Self.schema, energy: "price")
        var events = 0
        for i in 0..<20_000 {
            let t = Double(i) / 100
            let frame = sonifier.ingest(time: t, values: [i % 997 == 0 ? 50 : 1, 100 + sin(t / 3) + 0.05 * sin(t * 7)])
            events += frame.events.count
            #expect(frame.melody >= 0 && frame.melody <= 1)
        }
        // 200 s at ~2 events a second at most.
        #expect(events > 20 && events <= 2 * 200 + 8)
        #expect(sonifier.energyColumn == "price")
        #expect(sonifier.voiceColumns == ["size"])
        #expect(sonifier.index == 20_000)
    }

    @Test func sameSamplesGiveTheSameEvents() {
        func run() -> [String] {
            var sonifier = StreamSonifier(schema: Self.schema, energy: "price")
            var ids: [String] = []
            for i in 0..<6_000 {
                let t = Double(i) / 100
                ids += sonifier.ingest(time: t, values: [i % 211 == 0 ? 40 : 1, 100 + 3 * sin(t)]).events.map(\.id)
            }
            return ids
        }
        let first = run()
        #expect(first.count > 10)
        #expect(first == run())
    }

    @Test func columnsLeadByRankThenOrder() {
        let schema = StreamSchema(["index", "lat", "price", "other", "yield"])
        let rank = StreamColumnRanker { name in ["price": 2, "yield": 2, "index": 0, "lat": 0][name] ?? 1 }
        let ranked = StreamSonifier(schema: schema, ranker: rank)
        #expect(ranked.energyColumn == "price")
        #expect(ranked.voiceColumns == ["index", "lat", "other", "yield"])
        // No ranker: the first column leads. A named column overrides the ranker.
        #expect(StreamSonifier(schema: schema).energyColumn == "index")
        #expect(StreamSonifier(schema: schema, energy: "other", ranker: rank).energyColumn == "other")
        #expect(StreamSonifier(schema: schema, energy: "nope").energyColumn == "index")
    }

    @Test func promotingAColumnDemotesTheLeader() {
        var sonifier = StreamSonifier(schema: StreamSchema(["a", "b", "c"]))
        sonifier.setEnergy(column: "c")
        #expect(sonifier.energyColumn == "c")
        #expect(sonifier.voiceColumns == ["a", "b"])
        sonifier.setEnergy(column: "missing")
        #expect(sonifier.energyColumn == "c")
    }

    @Test func nonFiniteValuesAreSkipped() {
        var sonifier = StreamSonifier(schema: StreamSchema(["a", "b"]))
        _ = sonifier.ingest(time: 0, values: [.nan, 1])
        _ = sonifier.ingest(time: 1, values: [.infinity, 2])
        #expect(sonifier.series[0].count == 0)
        #expect(sonifier.series[1].count == 2)
    }

    @Test func aFirstSampleAnnouncesItself() {
        var sonifier = StreamSonifier(schema: Self.schema, energy: "price")
        let frame = sonifier.ingest(time: 0, values: [1, 42])
        #expect(frame.events.first?.kind == .crossing)
        #expect(frame.cues.count == 1)
    }

    @Test func aWholeStreamBecomesSignalsTheConductorPlays() {
        var sonifier = StreamSonifier(schema: Self.schema, energy: "price")
        var conductor = DropConductor(settings: SongSettings(bpm: 140, genre: .dubstep, seed: 1))
        var notes = 0
        var pending: [StreamFrame] = []
        for tick in 0..<(60 * 60) {
            let now = Double(tick) / 60
            // 20 samples a second, in ticks of 60 Hz.
            if tick % 3 == 0 {
                let t = Double(tick / 3) / 20
                pending.append(sonifier.ingest(time: t, values: [tick % 211 == 0 ? 40 : 1, 100 + 10 * sin(t / 2)]))
            }
            if !pending.isEmpty {
                let (signal, drop) = sonifier.signal(pending, time: now)
                conductor.ingest(signal)
                if drop { conductor.queueDrop() }
                pending.removeAll()
            }
            notes += conductor.advance(throughStep: Int(now / conductor.settings.secondsPerStep)).count
        }
        #expect(notes > 200)
    }

    @Test func signalOfNoFramesIsEmpty() {
        let sonifier = StreamSonifier(schema: Self.schema)
        let (signal, drop) = sonifier.signal([], time: 3)
        #expect(signal.cues.isEmpty && !drop)
    }

    @Test func openEventKindsCarryTheirOwnNames() {
        let kind: StreamEventKind = "brake"
        #expect(kind.rawValue == "brake" && kind != .peak)
        #expect(StreamEvent(index: 3, kind: kind, column: "g", detail: "").id == "3|brake|g")
    }
}

@Suite struct OnlineSeriesTests {
    @Test func nonFiniteValuesAreIgnored() {
        var series = OnlineSeries(name: "v")
        _ = series.add(.nan, time: 0)
        _ = series.add(.infinity, time: 1)
        #expect(series.count == 0)
    }

    @Test func selectMatchesSorting() {
        var random = Lcg()
        for size in [1, 2, 3, 7, 64, 513, 2048] {
            // Repeated values stress the partitioning; a constant run is the worst case for naive quickselect.
            let base = (0..<size).map { _ in (random.next() * 10).rounded() / 2 }
            for values in [base, [Double](repeating: 4, count: size), base.sorted(), base.sorted(by: >)] {
                let sorted = values.sorted()
                for rank in Set([0, size / 50, size / 2, Int(Double(size - 1) * 0.98), size - 1]) {
                    var copy = values
                    #expect(OnlineSeries.select(&copy, rank) == sorted[rank])
                }
            }
        }
    }

    @Test func rangeIsTheRobustPercentilesOfTheWindow() {
        var series = OnlineSeries(name: "v", window: 512)
        var random = Lcg()
        for i in 0..<5_000 { _ = series.add(random.next() * 10, time: Double(i) / 50) }
        // Uniform noise smoothed over 0.2 s: the 2nd ... 98th percentiles sit well inside 0 ... 10 and span most of it.
        #expect(series.range.lowerBound > 1 && series.range.upperBound < 9)
        #expect(series.range.upperBound - series.range.lowerBound > 2)
        #expect(series.level >= 0 && series.level <= 1)
    }
}
