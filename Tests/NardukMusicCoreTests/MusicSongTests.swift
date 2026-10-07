import Foundation
import NardukMusicDSP
import Testing

@testable import NardukMusicCore

/// Song-level variety (#45 follow-up: "the MUSIC sounded the same"). A session is a DJ set of tracks: each track has
/// its own key, tempo, hook and groove, repeats that hook, and hands over to the next when the traffic changes.
/// These tests drive the conductor with synthetic traffic of each kind and measure the songs, not the sounds.
@Suite struct MusicSongTests {
    // MARK: Synthetic traffic

    struct Segment {
        var character: MusicCharacter
        var seconds: Double
    }

    /// One step of traffic of the given kind at session time `t` (seconds), lasting `dt`.
    static func traffic(_ kind: MusicCharacter, t: Double, dt: Double, rng: inout MusicRNG) -> TrafficBatch {
        var events: [TrafficEvent] = []
        func maybe(
            _ perSecond: Double, _ event: TrafficEventKind, _ app: String, _ direction: TrafficDirection = .outbound
        ) {
            if rng.unit() < perSecond * dt {
                events.append(TrafficEvent(time: t, kind: event, direction: direction, app: app))
            }
        }
        let wobble = 1 + 0.08 * sin(t * 1.3) + 0.05 * (rng.unit() - 0.5)
        let bytesIn: Double
        let bytesOut: Double
        let app: String
        switch kind {
        case .idle:
            app = "com.apple.mail"
            bytesIn = 5_000 * wobble
            bytesOut = 2_000 * wobble
            maybe(0.3, .multicastDiscovery, app, .inbound)
            maybe(0.2, .dnsQuery, app)
        case .busy:
            app = "com.apple.Safari"
            // Page loads: a second or so of heavy transfer every few seconds, quiet reading in between.
            let loading = (t.truncatingRemainder(dividingBy: 3.7)) < 1.1
            bytesIn = (loading ? 7_000_000 : 250_000) * wobble
            bytesOut = bytesIn * 0.08
            maybe(3, .dnsQuery, app)
            maybe(3, .tcpSyn, app)
            let hosts = ["news.example.com", "cdn.example.net", "images.example.org", "api.example.io"]
            maybe(2.5, .tlsHello(serverName: hosts[Int(rng.next() % 4)]), app)
            maybe(0.3, .newDestination(host: hosts[Int(rng.next() % 4)]), app)
        case .steady:
            app = "us.zoom.xos"
            bytesIn = 450_000 * wobble
            bytesOut = 400_000 * wobble
            maybe(0.05, .tlsHello(serverName: "zoom.us"), app)
            maybe(0.1, .dnsQuery, app)
        case .surge:
            app = "com.valvesoftware.steam"
            bytesIn = 25_000_000 * wobble
            bytesOut = 500_000 * wobble
            maybe(0.2, .dnsQuery, app)
            maybe(0.2, .tcpSyn, app)
        case .chaos:
            app = "com.google.Chrome"
            let spike = (t.truncatingRemainder(dividingBy: 2.3)) < 0.6
            bytesIn = (spike ? 4_000_000 : 400_000) * wobble
            bytesOut = bytesIn * 0.3
            maybe(1.5, .tcpRst, app, .inbound)
            maybe(2.5, .retransmission, app)
            maybe(1, .dnsError, app, .inbound)
            maybe(0.3, .icmpUnreachable, app, .inbound)
            maybe(3, .tcpSyn, app)
            maybe(2, .dnsQuery, app)
        }
        let tick = ThroughputTick(
            time: t, interval: dt, bytesIn: Int(bytesIn * dt), bytesOut: Int(bytesOut * dt),
            packets: Int((bytesIn + bytesOut) * dt / 1_200), bytesPerApp: [app: Int((bytesIn + bytesOut) * dt)])
        return TrafficBatch(events: events, ticks: [tick])
    }

    // MARK: Performance (conductor only)

    struct Performance {
        var notes: [ScheduledNote] = []
        var sections: [SongSection] = []
        var tracks: [Track] = []
        var bpm: [Double] = []
        /// Session time at the start of each step.
        var time: [Double] = []
        var switches: [GenreSwitch] = []
        /// What the conductor heard the traffic as, per step.
        var heard: [MusicCharacter] = []
        var legend: [String] = []

        var steps: Int { sections.count }
        func step(at seconds: Double) -> Int { time.firstIndex { $0 >= seconds } ?? max(0, steps - 1) }
        var trackNumbers: [Int] { tracks.map(\.number).reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } } }
        var distinctTracks: [Track] {
            var seen = Set<Int>()
            return tracks.filter { seen.insert($0.number).inserted }.map { number in
                tracks.last { $0.number == number.number }!
            }
        }
    }

    static func perform(genre: Genre = .dubstep, seed: UInt64, segments: [Segment], extraSeconds: Double = 0)
        -> Performance
    {
        var settings = SongSettings(genre: genre)
        settings.seed = seed
        var conductor = DropConductor(settings: settings)
        var rng = MusicRNG(seed: seed ^ 0xA11CE)
        let total = segments.map(\.seconds).reduce(0, +) + extraSeconds
        var p = Performance()
        var t = 0.0
        var step = 0
        while t < total + 2 {
            let dt = conductor.settings.secondsPerStep
            var elapsed = 0.0
            let kind =
                segments.first { segment in
                    elapsed += segment.seconds
                    return t < elapsed
                }?.character ?? segments.last!.character
            conductor.ingest(traffic(kind, t: t, dt: dt, rng: &rng))
            p.time.append(t)
            p.notes += conductor.advance(throughStep: step)
            p.sections.append(conductor.snapshot.section)
            p.tracks.append(conductor.track)
            p.bpm.append(conductor.settings.bpm)
            p.heard.append(conductor.character)
            if let change = conductor.lastSwitch, p.switches.last != change { p.switches.append(change) }
            t += dt
            step += 1
        }
        p.legend = conductor.snapshot.legend
        return p
    }

    // MARK: Metrics

    /// The bass line of a two-bar pair as "position:interval above the key", the shape a listener remembers.
    static func bassSignature(_ p: Performance, pair: Int) -> Set<String> {
        let range = (pair * 32)..<((pair + 1) * 32)
        let notes = p.notes.filter { range.contains($0.step) && ($0.instrument == .wobble || $0.instrument == .sub) }
        let melodic = notes.contains { $0.instrument == .wobble } ? notes.filter { $0.instrument == .wobble } : notes
        return Set(
            melodic.map { note in
                let interval = (((note.params.pitch ?? 0) - p.tracks[note.step].keyRoot) % 12 + 12) % 12
                return "\(note.step - pair * 32):\(interval)"
            })
    }

    struct TrackStats {
        var track: Track
        var dropPairs = 0
        /// Share of the track's drop pairs (fill pairs aside) that play the same bass shape as the same pair of its other
        /// drop phrases: the hook coming back phrase after phrase. 1 is a hook that never changes; 0 never repeats.
        var repetition = 0.0
        /// The bass shape of the first pair of the track's drops: the hook as heard.
        var hookShape: Set<String> = []
    }

    static func trackStats(_ p: Performance) -> [TrackStats] {
        // Two-bar pairs by track and by slot within the phrase (the hook follows the chords, so slot 0 is compared
        // with slot 0 of the other phrases).
        var bySlot: [Int: [Int: [Set<String>]]] = [:]
        for pair in 0..<(p.steps / 32) {
            let step = pair * 32
            guard p.sections[step].isDrop, p.tracks[step].number == p.tracks[step + 31].number,
                (pair % 4) != 3
            else { continue }  // the phrase's last pair carries the fill and the ending
            bySlot[p.tracks[step].number, default: [:]][pair % 4, default: []].append(bassSignature(p, pair: pair))
        }
        return p.distinctTracks.map { track in
            var stats = TrackStats(track: track)
            let slots = bySlot[track.number] ?? [:]
            var repeated = 0
            for shapes in slots.values {
                stats.dropPairs += shapes.count
                let counts = Dictionary(shapes.map { ($0, 1) }, uniquingKeysWith: +)
                repeated += counts.values.max() ?? 0
            }
            // Pairs heard once (a track with a single drop phrase) prove nothing either way.
            let phrases = slots.values.map(\.count).max() ?? 0
            stats.repetition = phrases >= 2 ? Double(repeated) / Double(stats.dropPairs) : .nan
            stats.hookShape = slots[0]?.first ?? []
            return stats
        }
    }

    static func jaccardDistance(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : 1 - Double(a.intersection(b).count) / Double(union)
    }

    /// Wobble-rate changes per minute between consecutive wobble notes, over the performance.
    static func rateChangesPerMinute(_ p: Performance, from: Int = 0) -> Double {
        let wobbles = p.notes.filter { $0.instrument == .wobble && $0.step >= from }.sorted { $0.step < $1.step }
        let changes = zip(wobbles, wobbles.dropFirst()).filter { $0.params.wobbleRate != $1.params.wobbleRate }.count
        let minutes = (p.time.last! - p.time[min(from, p.steps - 1)]) / 60
        return Double(changes) / max(minutes, 1e-9)
    }

    static let set: [Segment] = [
        Segment(character: .idle, seconds: 25), Segment(character: .busy, seconds: 45),
        Segment(character: .steady, seconds: 45),
        Segment(character: .surge, seconds: 40), Segment(character: .chaos, seconds: 25),
    ]

    // MARK: Tests

    @Test func theCharacterizerHearsEachKindOfTraffic() {
        for kind in MusicCharacter.allCases {
            var c = FlowCharacterizer()
            var rng = MusicRNG(seed: 9)
            let dt = SongSettings().secondsPerStep
            for step in 0..<Int(30 / dt) {
                let batch = Self.traffic(kind, t: Double(step) * dt, dt: dt, rng: &rng)
                let tallies = batch.events.map { TrafficAdapter.tally($0.kind) }
                c.observe(
                    bytesIn: Double(batch.ticks.map(\.bytesIn).reduce(0, +)),
                    bytesOut: Double(batch.ticks.map(\.bytesOut).reduce(0, +)),
                    connections: tallies.map(\.connections).reduce(0, +), errors: tallies.map(\.errors).reduce(0, +),
                    seconds: dt)
            }
            #expect(c.current == kind, "\(kind) read as \(c.current)")
        }
    }

    @Test func aSetMovesThroughTracksAsTheTrafficChanges() {
        let p = Self.perform(seed: 0xA, segments: Self.set)
        let tracks = p.distinctTracks
        #expect(tracks.count >= 3, "\(p.trackNumbers)")
        // Every hand-over lands on a phrase boundary.
        for step in 1..<p.steps where p.tracks[step].number != p.tracks[step - 1].number {
            #expect(step % 128 == 0, "track changed mid-phrase at \(step)")
        }
        // The tracks follow the room: a call and a download each get a record of their own.
        // The tracks follow the room (a character must hold for a while, and a track for a few phrases, so a short
        // stretch of one kind of traffic steers the playing track rather than getting its own).
        let characters = Set(tracks.map(\.character))
        #expect(characters.count >= 3, "\(tracks.map(\.character))")
        #expect(!characters.isDisjoint(with: [.steady, .surge]), "\(tracks.map(\.character))")
        // Neighbouring tracks are different songs: key or mode, hook and tempo all move.
        for (a, b) in zip(tracks, tracks.dropFirst()) {
            #expect(a.keyName != b.keyName || a.hook.distance(to: b.hook) > 0.5, "\(a.name) → \(b.name)")
            #expect(a.hook.distance(to: b.hook) > 0.3, "\(a.name) → \(b.name)")
        }
        #expect(Set(tracks.map(\.bpm)).count >= 2, "\(tracks.map(\.bpm))")
        // Tempo changes reach the audio clock on bar lines only.
        #expect(p.switches.allSatisfy { $0.step % 16 == 0 })
    }

    @Test func hooksRepeatWithinATrack() {
        for genre in Genre.allCases {
            let p = Self.perform(genre: genre, seed: 3, segments: [Segment(character: .busy, seconds: 120)])
            let stats = Self.trackStats(p).filter { !$0.repetition.isNaN }
            #expect(!stats.isEmpty, "\(genre) never dropped")
            for s in stats { #expect(s.repetition >= 0.5, "\(genre) \(s.track.name) repetition \(s.repetition)") }
        }
    }

    @Test func wobbleRateChangesOnlyBySection() {
        for genre in Genre.allCases {
            let p = Self.perform(genre: genre, seed: 5, segments: [Segment(character: .busy, seconds: 150)])
            #expect(Self.rateChangesPerMinute(p) <= 4, "\(genre) \(Self.rateChangesPerMinute(p))/min")
            // One patch per track and section: the bass sound never shuffles within a phrase.
            for phrase in 0..<(p.steps / 128) {
                let voices = Set(
                    p.notes.filter { $0.instrument == .wobble && $0.step / 128 == phrase }.compactMap(\.params.voice))
                #expect(voices.count <= 1, "\(genre) phrase \(phrase) voices \(voices)")
            }
        }
    }

    @Test func sessionsDifferAndASeedIsDeterministic() {
        let segments = [Segment(character: .busy, seconds: 60)]
        let a = Self.perform(seed: 0xA, segments: segments)
        let b = Self.perform(seed: 0xB, segments: segments)
        let again = Self.perform(seed: 0xA, segments: segments)
        #expect(a.notes == again.notes)
        let ta = a.tracks.last!
        let tb = b.tracks.last!
        #expect(ta.hook.distance(to: tb.hook) > 0.3)
        #expect(ta.keyName != tb.keyName || ta.name != tb.name)
        // Each play() picks a new seed from the clock.
        #expect(
            SongSettings.sessionSeed(now: Date(timeIntervalSince1970: 1_000))
                != SongSettings.sessionSeed(now: Date(timeIntervalSince1970: 1_001)))
    }

    @Test func theKindOfTrafficWritesADifferentTune() {
        var hooks: [MusicCharacter: Track] = [:]
        for kind in [MusicCharacter.steady, .busy, .surge] {
            let p = Self.perform(seed: 0xC, segments: [Segment(character: kind, seconds: 45)])
            hooks[kind] = p.tracks.last!
            #expect(p.tracks.last!.character == kind, "\(kind) wrote a \(p.tracks.last!.character) track")
        }
        let kinds = Array(hooks.keys)
        for i in 0..<kinds.count {
            for j in (i + 1)..<kinds.count {
                let a = hooks[kinds[i]]!
                let b = hooks[kinds[j]]!
                #expect(a.hook.distance(to: b.hook) > 0.3, "\(kinds[i]) vs \(kinds[j])")
            }
        }
        // A download pushes the tempo up from a call's.
        #expect(hooks[.surge]!.bpm >= hooks[.steady]!.bpm)
    }

    @Test func genresSoundLikeThemselves() {
        var hooks: [Genre: Hook] = [:]
        for genre in Genre.allCases {
            let p = Self.perform(genre: genre, seed: 7, segments: [Segment(character: .busy, seconds: 70)])
            let track = p.tracks.last!
            hooks[genre] = track.hook
            let range = TrackGenerator.tempoRange(genre)
            #expect(range.contains(track.bpm), "\(genre) at \(track.bpm)")
            let dropBars = (0..<(p.steps / 16)).filter { p.sections[$0 * 16].isDrop && $0 % 8 != 7 && $0 % 8 != 3 }
            #expect(!dropBars.isEmpty, "\(genre) never dropped")
            // Chill's, folk's, lo-fi's and techno's backbeats are soft; everyone else's lands hard.
            let loudest = [.chill, .lofi, .techno, .folk].contains(genre) ? 0.5 : 0.9
            func hits(_ instrument: Instrument, _ bar: Int, loud: Bool = true) -> [Int] {
                p.notes.filter {
                    $0.instrument == instrument && $0.step / 16 == bar && (!loud || $0.velocity >= loudest)
                }.map { $0.step % 16 }
            }
            for bar in dropBars {
                switch genre {
                case .dubstep, .riddim, .trap, .chill:
                    #expect(hits(.snare, bar) == [8], "\(genre) half-time snare bar \(bar)")
                case .drumAndBass, .ukGarage, .synthwave, .lofi, .rock, .folk, .funk:
                    // A song may play its backbeat at half time (narduk-libs#1617): the snare moves to 3.
                    let expected = p.tracks[bar * 16].halfTime && Variety.halfTimes(genre) ? [8] : [4, 12]
                    #expect(hits(.snare, bar) == expected, "\(genre) backbeat bar \(bar)")
                case .house, .techno:
                    #expect(
                        Set([0, 4, 8, 12]).isSubset(of: Set(hits(.kick, bar, loud: false))), "house four-to-the-floor")
                }
            }
            let notes = p.notes.filter { p.sections[$0.step].isDrop }
            switch genre {
            case .trap:
                #expect(
                    !notes.contains { $0.instrument == .wobble }
                        && notes.contains { $0.instrument == .sub && $0.params.glide != nil })
            case .riddim:
                #expect(
                    notes.filter { $0.instrument == .wobble }.allSatisfy {
                        [.eighthTriplet, .sixteenthTriplet].contains($0.params.wobbleRate)
                    })
            case .house: #expect(notes.contains { $0.instrument == .keys })
            case .chill, .ukGarage, .lofi:
                #expect(notes.contains { $0.instrument == .keys } && notes.contains { ($0.params.delay ?? 0) > 0 })
            case .techno:
                #expect(notes.contains { $0.instrument == .keys } && notes.contains { $0.instrument == .sub })
            case .synthwave:
                #expect(notes.contains { $0.instrument == .keys } && notes.contains { $0.instrument == .wobble })
            case .dubstep, .drumAndBass: #expect(notes.contains { $0.instrument == .wobble })
            case .rock:
                #expect(
                    notes.contains { $0.instrument == .electricStrum && $0.params.voice == 4 }
                        && notes.contains { $0.instrument == .bassGuitar }
                        && !notes.contains { $0.instrument == .wobble || $0.instrument == .sub })
            case .folk:
                #expect(notes.contains { $0.instrument == .strum } && notes.contains { $0.instrument == .bassGuitar })
            case .funk:
                #expect(
                    notes.contains { $0.instrument == .electricStrum && [2, 3].contains($0.params.voice) }
                        && notes.contains { $0.instrument == .bassGuitar }
                        && notes.contains { ($0.params.delay ?? 0) > 0 })
            }
        }
        let genres = Array(hooks.keys)
        var distances: [Double] = []
        for i in 0..<genres.count {
            for j in (i + 1)..<genres.count { distances.append(hooks[genres[i]]!.distance(to: hooks[genres[j]]!)) }
        }
        #expect(distances.reduce(0, +) / Double(distances.count) > 0.5)
    }

    // MARK: Report (prints the metrics; renders WAVs when MUSIC_SONGS_DIR is set)

    @Test func report() throws {
        var lines: [String] = []
        func describe(_ label: String, _ p: Performance) {
            let stats = Self.trackStats(p)
            lines.append(
                "\(label): \(p.trackNumbers.count - 1) track changes in \(Int(p.time.last!)) s, "
                    + String(format: "wobble-rate changes %.1f/min", Self.rateChangesPerMinute(p)))
            for s in stats {
                lines.append(
                    String(
                        format: "  #%d %@ · %@ · %.0f BPM · %@ · hook repetition %.2f over %d drop pairs · %@",
                        s.track.number, s.track.name, s.track.keyName, s.track.bpm, s.track.character.rawValue,
                        s.repetition, s.dropPairs, s.track.hookDescription))
            }
            for (a, b) in zip(stats, stats.dropFirst()) {
                lines.append(
                    String(
                        format: "  hook distance #%d→#%d: written %.2f, heard %.2f", a.track.number, b.track.number,
                        a.track.hook.distance(to: b.track.hook), Self.jaccardDistance(a.hookShape, b.hookShape)))
            }
        }
        let dir = ProcessInfo.processInfo.environment["MUSIC_SONGS_DIR"]
        func path(_ name: String) -> String? { dir.map { "\($0)/\(name).wav" } }

        let set = Self.perform(seed: 0xA, segments: Self.set)
        describe("set (idle→browsing→call→download→chaos)", set)
        try Self.render(set, from: 0, seconds: 180, to: path("set-3min"))

        var sessionTracks: [Track] = []
        for (name, seed) in [("session-seedA", UInt64(0xA)), ("session-seedB", UInt64(0xB))] {
            let p = Self.perform(seed: seed, segments: [Segment(character: .busy, seconds: 120)])
            describe(name, p)
            sessionTracks.append(p.distinctTracks.first!)
            try Self.render(p, from: Self.startBeforeDrop(p, seconds: 60), seconds: 60, to: path(name))
        }
        lines.append(
            String(
                format: "seed A vs seed B first-track hook distance %.2f",
                sessionTracks[0].hook.distance(to: sessionTracks[1].hook)))

        var genreHooks: [Hook] = []
        for genre in Genre.allCases {
            let p = Self.perform(genre: genre, seed: 0xA, segments: [Segment(character: .busy, seconds: 90)])
            describe("genre-\(genre.rawValue)", p)
            genreHooks.append(p.tracks.last!.hook)
            try Self.render(
                p, from: Self.startBeforeDrop(p, seconds: 30), seconds: 30, to: path("genre-\(genre.rawValue)"))
        }
        var genreDistances: [Double] = []
        for i in 0..<genreHooks.count {
            for j in (i + 1)..<genreHooks.count { genreDistances.append(genreHooks[i].distance(to: genreHooks[j])) }
        }
        lines.append(
            String(
                format: "genre hook distance: mean %.2f, min %.2f",
                genreDistances.reduce(0, +) / Double(genreDistances.count),
                genreDistances.min() ?? 0))

        var trafficHooks: [Hook] = []
        for kind in [MusicCharacter.steady, .busy, .surge] {
            let p = Self.perform(seed: 0xC, segments: [Segment(character: kind, seconds: 120)])
            describe("traffic-\(kind.rawValue)", p)
            trafficHooks.append(p.distinctTracks.first { $0.character == kind }?.hook ?? p.tracks.last!.hook)
            try Self.render(
                p, from: Self.startBeforeDrop(p, seconds: 45), seconds: 45, to: path("traffic-\(kind.rawValue)"))
        }
        lines.append(
            String(
                format: "traffic hook distance: call-browsing %.2f, call-download %.2f, browsing-download %.2f",
                trafficHooks[0].distance(to: trafficHooks[1]), trafficHooks[0].distance(to: trafficHooks[2]),
                trafficHooks[1].distance(to: trafficHooks[2])))
        print(lines.joined(separator: "\n"))
        if let dir {
            try lines.joined(separator: "\n").write(toFile: dir + "/metrics.txt", atomically: true, encoding: .utf8)
        }
    }

    /// Eight bars before the first drop, or the start when the window would run past the end.
    static func startBeforeDrop(_ p: Performance, seconds: Double) -> Int {
        guard let drop = p.sections.firstIndex(where: \.isDrop) else { return 0 }
        let start = max(0, drop - 8 * 16)
        return p.time[start] + seconds <= p.time.last! ? start : 0
    }

    // MARK: Offline render

    /// Renders `seconds` of the performance from step `from`, following its tempo changes on the bar lines where the
    /// conductor made them. Writes a 16-bit WAV when `path` is set; returns nothing when it is nil (no audio work).
    static func render(_ p: Performance, from start: Int, seconds: Double, to path: String?) throws {
        guard let path else { return }
        let sampleRate = 48_000.0
        let core = DropSynthCore(sampleRate: sampleRate, bpm: p.bpm[start])
        core.setMasterVolume(1)
        let frames = Int(seconds * sampleRate)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        let notes = p.notes.filter { $0.step >= start }.sorted { $0.step < $1.step }
        var tempo = p.switches.filter { $0.step > start }.map { (step: $0.step - start, bpm: $0.bpm) }
        var index = 0
        var rendered = 0
        while rendered < frames {
            let position = core.renderedStepPosition
            // A tempo change is requested during the bar before its bar line, as the app's clock does.
            while let next = tempo.first, position >= Double(next.step - 16) {
                core.setTempo(next.bpm)
                tempo.removeFirst()
            }
            let secondsPerStep = 60 / p.bpm[min(p.steps - 1, start + Int(position))] / 4
            let through = Int(position + 0.1 / secondsPerStep) + start
            while index < notes.count, notes[index].step <= through {
                var note = notes[index]
                note.step -= start
                core.schedule(note)
                index += 1
            }
            let n = min(512, frames - rendered)
            core.render(frames: n, left: left + rendered, right: right + rendered)
            rendered += n
        }
        try WAVWriter.write16(
            left: left, right: right, frames: frames, sampleRate: Int(sampleRate), to: URL(fileURLWithPath: path))
    }
}
