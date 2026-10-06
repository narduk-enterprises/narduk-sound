import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct DropConductorTests {
    static let settings = SongSettings()
    static var phrase: Int { settings.stepsPerPhrase }
    static var bar: Int { settings.stepsPerBar }

    /// Two 50 ms ticks of the given bytes per tick: about one step of traffic.
    static func traffic(bytesPerTick: Int, events: [TrafficEventKind] = [], app: String = "com.apple.Safari")
        -> TrafficBatch
    {
        let ticks = (0..<2).map { index in
            ThroughputTick(
                time: Double(index) * 0.05, interval: 0.05, bytesIn: bytesPerTick * 3 / 4, bytesOut: bytesPerTick / 4,
                packets: bytesPerTick / 1_000, bytesPerApp: [app: bytesPerTick])
        }
        return TrafficBatch(
            events: events.map { TrafficEvent(time: 0, kind: $0, direction: .outbound, app: app) }, ticks: ticks)
    }

    static let loud = traffic(bytesPerTick: 2_500_000)
    static let quiet = TrafficBatch()

    struct Recording {
        var notes: [ScheduledNote] = []
        var sections: [SongSection] = []  // section at each step
        var snapshots: [ConductorSnapshot] = []
        var tracks: [Track] = []  // the track playing at each step

        /// Whether a pitched note sits in the key and mode of the track that played it.
        func inKey(_ note: ScheduledNote) -> Bool {
            let track = tracks[note.step]
            return track.mode.contains(semitones: (note.params.pitch ?? 0) - track.keyRoot)
        }
    }

    /// Plays steps 0 ..< count, feeding `batch(step)` before each step.
    static func play(_ conductor: inout DropConductor, steps count: Int, batch: (Int) -> TrafficBatch) -> Recording {
        var recording = Recording()
        for step in 0..<count {
            conductor.ingest(batch(step))
            recording.notes += conductor.advance(throughStep: step)
            recording.sections.append(conductor.snapshot.section)
            recording.snapshots.append(conductor.snapshot)
            recording.tracks.append(conductor.track)
        }
        return recording
    }

    static func rampThenSettle(_ step: Int) -> TrafficBatch {
        switch step / phrase {
        case 0, 1: quiet
        case 2...6: loud
        default: quiet
        }
    }

    /// A deterministic mix of everything the deriver can emit.
    static func busy(_ step: Int) -> TrafficBatch {
        var generator = MusicRNG(seed: UInt64(step) &* 7919 &+ 1)
        let pool: [TrafficEventKind] = [
            .dnsQuery, .dnsQuery, .dnsError, .tlsHello(serverName: "api.github.com"), .tcpSyn, .tcpSyn, .tcpRst,
            .retransmission,
            .icmpReply(rtt: 0.02), .icmpUnreachable, .multicastDiscovery, .newDestination(host: "example.com"),
            .newApp(bundleID: "us.zoom.xos"),
        ]
        let events = (0..<Int(generator.next() % 12)).map { _ in pool[Int(generator.next() % UInt64(pool.count))] }
        return traffic(bytesPerTick: step % 300 < 150 ? 2_500_000 : 4_000, events: events)
    }

    @Test func sameInputSameNotes() {
        var first = DropConductor(settings: Self.settings)
        var second = DropConductor(settings: Self.settings)
        let a = Self.play(&first, steps: Self.phrase * 6, batch: Self.busy)
        let b = Self.play(&second, steps: Self.phrase * 6, batch: Self.busy)
        #expect(!a.notes.isEmpty)
        #expect(a.notes == b.notes)
        #expect(a.snapshots == b.snapshots)

        var other = SongSettings()
        other.seed = 42
        var different = DropConductor(settings: other)
        let c = Self.play(&different, steps: Self.phrase * 6, batch: Self.busy)
        #expect(c.notes != a.notes)
    }

    @Test func notesAreOnTheGridAndNeverRepeatAStep() {
        var conductor = DropConductor(settings: Self.settings)
        var emitted = Set<Int>()
        var through = -1
        var all: [ScheduledNote] = []
        // Irregular catch-up sizes, including the same step twice.
        for target in [0, 0, 3, 3, 4, 20, 20, 21, 130, 130, 300, 299, 301] {
            conductor.ingest(Self.busy(target))
            let notes = conductor.advance(throughStep: target)
            if target <= through { #expect(notes.isEmpty) }
            for note in notes {
                #expect(note.step > through && note.step <= target)
                #expect(note.velocity >= 0 && note.velocity <= 1)
                #expect(note.params.lengthSteps >= 1)
            }
            // Each step's notes arrive in one call: no step is ever split across calls or repeated.
            let steps = Set(notes.map(\.step))
            #expect(steps.isDisjoint(with: emitted))
            emitted.formUnion(steps)
            through = max(through, target)
            all += notes
        }
        #expect(all.map(\.step) == all.map(\.step).sorted())
        #expect(conductor.snapshot.step == 301)
    }

    @Test func sectionsOnlyChangeOnPhraseBoundaries() {
        var conductor = DropConductor(settings: Self.settings)
        let recording = Self.play(&conductor, steps: Self.phrase * 12, batch: Self.rampThenSettle)
        var changes = 0
        for step in 1..<recording.sections.count where recording.sections[step] != recording.sections[step - 1] {
            #expect(step % Self.phrase == 0, "section changed mid-phrase at step \(step)")
            changes += 1
        }
        #expect(changes >= 3)
        #expect(recording.sections.first == .intro)
    }

    @Test func aHighEnergyRampBuildsAndDrops() {
        var conductor = DropConductor(settings: Self.settings)
        let recording = Self.play(&conductor, steps: Self.phrase * 12, batch: Self.rampThenSettle)
        let order = recording.sections.reduce(into: [SongSection]()) { if $0.last != $1 { $0.append($1) } }
        #expect(order.starts(with: [.intro, .build, .drop]))
        #expect(order.contains(.breakdown))
        // Energy followed the traffic up and back down.
        #expect(recording.snapshots[Self.phrase * 5].energy > 0.9)
        #expect(recording.snapshots.last!.energy < 0.4)
        // The build ends with a riser and a snare roll, and the drop opens with an impact.
        let dropStart = recording.sections.firstIndex(of: .drop)!
        let build = recording.notes.filter { $0.step >= dropStart - Self.bar && $0.step < dropStart }
        #expect(build.contains { $0.instrument == .riser })
        #expect(build.filter { $0.instrument == .snare }.count >= 6)
        #expect(recording.notes.contains { $0.step == dropStart && $0.instrument == .impact })
        // Quiet traffic never wobbles; the drop does.
        #expect(recording.notes.filter { $0.instrument == .wobble }.allSatisfy { recording.sections[$0.step].isDrop })
        #expect(recording.notes.contains { $0.instrument == .wobble })
    }

    @Test func quietTrafficStaysInTheIntro() {
        var conductor = DropConductor(settings: Self.settings)
        let recording = Self.play(&conductor, steps: Self.phrase * 4) { _ in Self.quiet }
        #expect(Set(recording.sections) == [.intro])
        #expect(!recording.notes.contains { $0.instrument == .wobble || $0.instrument == .sub })
    }

    @Test func queueDropForcesTheDropAtTheNextBoundary() {
        var conductor = DropConductor(settings: Self.settings)
        _ = Self.play(&conductor, steps: 20) { _ in Self.quiet }
        conductor.queueDrop()
        #expect(conductor.snapshot.dropQueued)
        var notes: [ScheduledNote] = []
        var sections: [SongSection] = []
        for step in 20..<(Self.phrase + 8) {
            conductor.ingest(Self.quiet)
            notes += conductor.advance(throughStep: step)
            sections.append(conductor.snapshot.section)
        }
        #expect(sections[Self.phrase - 21] == .intro)  // still intro on the last step of the phrase
        #expect(sections[Self.phrase - 20] == .drop)  // drop exactly on the boundary
        #expect(!conductor.snapshot.dropQueued)
        #expect(notes.contains { $0.step == Self.phrase && $0.instrument == .impact })
        #expect(notes.contains { $0.instrument == .riser })
        #expect(notes.contains { $0.step == Self.phrase && $0.instrument == .wobble })
    }

    @Test func queueDropFromABuildAndLateInTheLastBar() {
        var conductor = DropConductor(settings: Self.settings)
        // Enough energy to build, then a low-energy tail that would otherwise collapse.
        let recording = Self.play(&conductor, steps: Self.phrase * 2 - 6) {
            $0 < Self.phrase + 20 ? Self.loud : Self.quiet
        }
        #expect(recording.sections.last == .build)
        conductor.queueDrop()  // six steps before the boundary
        var late: [ScheduledNote] = []
        for step in (Self.phrase * 2 - 6)..<(Self.phrase * 2) {
            late += conductor.advance(throughStep: step)
        }
        #expect(late.contains { $0.instrument == .riser && $0.params.lengthSteps == 6 })  // ends on the drop
        _ = conductor.advance(throughStep: Self.phrase * 2)
        #expect(conductor.snapshot.section == .drop)
    }

    @Test func thresholdsAreClamped() {
        var conductor = DropConductor(settings: Self.settings)
        conductor.setThresholds(build: 0.7, drop: 0.5)
        #expect(conductor.snapshot.buildThreshold == 0.7 && conductor.snapshot.dropThreshold == 0.5)
        conductor.setThresholds(build: 2, drop: 3)
        #expect(conductor.snapshot.buildThreshold == 1 && conductor.snapshot.dropThreshold == 1)
        conductor.setThresholds(build: 0.3, drop: -1)
        #expect(conductor.snapshot.buildThreshold == 0.3 && conductor.snapshot.dropThreshold == 0)
        // A lower build threshold lets modest traffic build.
        var eager = DropConductor(settings: Self.settings)
        eager.setThresholds(build: 0.05, drop: 0.02)
        let recording = Self.play(&eager, steps: Self.phrase * 3) { _ in Self.traffic(bytesPerTick: 20_000) }
        #expect(recording.sections.contains(.build))
    }

    @Test func densityCapsHold() {
        var conductor = DropConductor(settings: Self.settings)
        // A flood: every step carries a dozen of every kind, in the middle of a drop.
        let kinds: [TrafficEventKind] = [
            .dnsQuery, .dnsError, .tlsHello(serverName: "a.example"), .tcpSyn, .tcpRst, .retransmission,
            .icmpReply(rtt: 0.01),
            .icmpUnreachable, .multicastDiscovery, .newDestination(host: "x.example"), .newApp(bundleID: "app"),
            .newLANHost, .wifiEvent,
        ]
        let flood = Array((0..<12).map { _ in kinds }.joined())
        let recording = Self.play(&conductor, steps: Self.phrase * 6) { step in
            Self.traffic(bytesPerTick: step >= Self.phrase ? 2_500_000 : 0, events: flood)
        }
        #expect(recording.sections.contains(.drop))
        var perBar: [Int: [Instrument: Int]] = [:]
        var tapeStopsPerPhrase: [Int: Int] = [:]
        var voxBars: [Int] = []
        for note in recording.notes {
            let bar = note.step / Self.bar
            perBar[bar, default: [:]][note.instrument, default: 0] += 1
            if note.instrument == .tapeStop { tapeStopsPerPhrase[note.step / Self.phrase, default: 0] += 1 }
            if note.instrument == .vox { voxBars.append(bar) }
        }
        for (bar, counts) in perBar {
            for (instrument, cap) in DropConductor.eventCaps {
                #expect(
                    counts[instrument, default: 0] <= cap,
                    "\(instrument) took \(counts[instrument, default: 0]) in bar \(bar)")
            }
        }
        #expect(tapeStopsPerPhrase.values.allSatisfy { $0 <= 1 })
        #expect(!voxBars.isEmpty)
        // Traffic vox chops (velocity 0.8) keep two bars apart; a breakdown's vocal lead is quieter and structural.
        let eventVox = recording.notes.filter { $0.instrument == .vox && $0.velocity >= 0.7 }.map { $0.step / Self.bar }
        #expect(zip(eventVox, eventVox.dropFirst()).allSatisfy { $1 - $0 >= 2 })
        // The flood is bounded in total too: nothing like 156 events per step reaches the grid.
        let eventNotes = recording.notes.filter { DropConductor.eventCaps[$0.instrument] != nil }
        #expect(eventNotes.count <= (Self.phrase * 6 / Self.bar) * DropConductor.eventCaps.values.reduce(0, +))
    }

    @Test func snareLandsOnBeatThreeOfEveryDropBar() {
        var conductor = DropConductor(settings: Self.settings)
        let recording = Self.play(&conductor, steps: Self.phrase * 8, batch: Self.busy)
        var dropBars = 0
        for bar in 0..<(recording.sections.count / Self.bar) {
            guard recording.sections[bar * Self.bar].isDrop else { continue }
            dropBars += 1
            let backbeat = recording.notes.filter { $0.step == bar * Self.bar + 8 && $0.instrument == .snare }
            #expect(backbeat.contains { $0.velocity >= 0.9 }, "no snare on step 8 of bar \(bar)")
            #expect(recording.notes.contains { $0.step == bar * Self.bar && $0.instrument == .kick })
            // Half-time: no loud snare anywhere else in the bar, except the fill that ends a phrase.
            guard bar % Self.settings.barsPerPhrase != Self.settings.barsPerPhrase - 1 else { continue }
            let loud = recording.notes.filter {
                $0.step / Self.bar == bar && $0.instrument == .snare && $0.velocity >= 0.5
            }
            #expect(loud.allSatisfy { $0.step == bar * Self.bar + 8 })
        }
        #expect(dropBars >= 8)
    }

    @Test func bassIsInKeyAndKeepsItsPatchThroughASection() {
        var conductor = DropConductor(settings: Self.settings)
        let recording = Self.play(&conductor, steps: Self.phrase * 6) { step in
            step < Self.phrase ? Self.quiet : Self.traffic(bytesPerTick: 2_500_000, app: "com.spotify.client")
        }
        let wobbles = recording.notes.filter { $0.instrument == .wobble }
        #expect(!wobbles.isEmpty)
        for note in wobbles + recording.notes.filter({ $0.instrument == .sub }) {
            #expect(
                recording.inKey(note), "pitch \(note.params.pitch ?? 0) out of \(recording.tracks[note.step].keyName)")
        }
        // A track keeps its patch and wobble rate through a section: no per-note or per-phrase shuffling (#54 trim).
        var perSection: [String: Set<String>] = [:]
        for note in wobbles where recording.sections[note.step].isDrop {
            let key = "\(recording.tracks[note.step].number)-\(recording.sections[note.step])"
            perSection[key, default: []].insert("\(note.params.voice ?? -1)/\(note.params.wobbleRate?.rawValue ?? "")")
        }
        #expect(!perSection.isEmpty)
        #expect(perSection.values.allSatisfy { $0.count == 1 }, "\(perSection)")
        #expect(conductor.snapshot.track != nil)
        #expect((wobbles.last?.params.pan ?? 1) < 0)
    }

    @Test func eventsMapToTheirInstruments() {
        func first(_ kind: TrafficEventKind, direction: TrafficDirection = .outbound, steps: Int = 8) -> ScheduledNote?
        {
            var c = DropConductor(settings: Self.settings)
            _ = c.advance(throughStep: 3)
            c.ingest(TrafficBatch(events: [TrafficEvent(time: 0, kind: kind, direction: direction, app: nil)]))
            let notes = c.advance(throughStep: 3 + steps)
            return notes.first { $0.step > 3 && $0.instrument != .kick && $0.instrument != .hat }
        }
        #expect(first(.tlsHello(serverName: "api.github.com"))?.instrument == .laser)
        #expect(first(.dnsError)?.instrument == .glitch)
        #expect(first(.tcpRst)?.instrument == .impact)
        #expect(first(.retransmission)?.instrument == .scratch)
        #expect(first(.icmpUnreachable)?.instrument == .tapeStop)
        #expect(first(.newDestination(host: "example.com"))?.instrument == .vox)
        #expect(first(.tcpSyn)?.instrument == .snare)
        #expect((first(.tcpSyn)?.velocity ?? 1) < 0.5)
        #expect((first(.tlsHello(serverName: nil), direction: .inbound)?.params.pan ?? 1) < 0)
        #expect((first(.tlsHello(serverName: nil), direction: .outbound)?.params.pan ?? -1) > 0)
    }

    @Test func legendExplainsWhatDroveTheNotes() {
        var conductor = DropConductor(settings: Self.settings)
        _ = Self.play(&conductor, steps: 4) { _ in Self.quiet }
        conductor.ingest(
            TrafficBatch(events: [
                TrafficEvent(
                    time: 0, kind: .tlsHello(serverName: "api.github.com"),
                    direction: .outbound, app: nil)
            ]))
        _ = conductor.advance(throughStep: 12)
        #expect(conductor.snapshot.legend.contains("laser ← TLS api.github.com"))
        #expect(conductor.snapshot.legend.count <= 8)
    }

    @Test func stableHashIsFNV1a() {
        #expect(StableHash.fnv1a("") == 0xCBF2_9CE4_8422_2325)
        #expect(StableHash.fnv1a("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(StableHash.fnv1a("com.apple.Safari") == StableHash.fnv1a("com.apple.Safari"))
    }
}
