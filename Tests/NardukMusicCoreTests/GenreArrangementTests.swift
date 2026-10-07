import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct GenreArrangementTests {
    typealias Base = DropConductorTests
    static let bar = 16
    static let scale: Set<Int> = [0, 2, 3, 5, 7, 8, 10]

    static func conductor(_ genre: Genre) -> DropConductor { DropConductor(settings: SongSettings(genre: genre)) }

    /// Loud from the first step: INTRO for a phrase, BUILD for a phrase, then DROP from step 256.
    static func loudRun(_ genre: Genre, steps: Int, events: @escaping (Int) -> TrafficBatch = { _ in Base.loud })
        -> Base.Recording
    {
        var c = conductor(genre)
        return Base.play(&c, steps: steps, batch: events)
    }

    /// Everything the deriver can emit, on top of constant heavy traffic.
    static func busyLoud(_ step: Int) -> TrafficBatch {
        TrafficBatch(events: Base.busy(step).events, ticks: Base.loud.ticks)
    }

    static func dropBars(_ r: Base.Recording) -> [Int] {
        (0..<(r.sections.count / bar)).filter { r.sections[$0 * bar].isDrop }
    }

    /// Bars with no fill: not the last bar of a phrase (its fill) nor the half-phrase bar (a fill's last beat).
    static func plainBars(_ bars: [Int]) -> [Int] { bars.filter { $0 % 8 != 7 && $0 % 8 != 3 } }

    static func hits(_ r: Base.Recording, _ instrument: Instrument, bar index: Int, minVelocity: Double = 0) -> [Int] {
        r.notes.filter { $0.instrument == instrument && $0.step / bar == index && $0.velocity >= minVelocity }.map {
            $0.step % bar
        }
    }

    // MARK: Every genre

    @Test func everyGenreHasItsOwnTempoAndPlays() {
        #expect(Genre.allCases.map(\.defaultBPM) == [140, 140, 174, 140, 124, 88, 132, 132, 108, 80, 124, 96, 104])
        for genre in Genre.allCases {
            let settings = SongSettings(genre: genre)
            #expect(settings.genre == genre && settings.bpm == genre.defaultBPM)
            let r = Self.loudRun(genre, steps: 256 + 8 * Self.bar, events: Self.busyLoud)
            let drops = Self.dropBars(r)
            #expect(drops.count >= 8, "\(genre) never dropped")
            #expect(r.notes.contains { $0.instrument == .kick }, "\(genre) has no kick")
            #expect(r.notes.contains { $0.instrument == .snare && $0.velocity >= 0.5 }, "\(genre) has no snare")
            #expect(
                r.notes.contains { $0.instrument == .sub || $0.instrument == .bassGuitar }, "\(genre) has no low end")
            for note in r.notes {
                #expect(note.velocity >= 0 && note.velocity <= 1 && note.params.lengthSteps >= 1)
            }
        }
    }

    @Test func eachGenreIsDeterministicAndDistinct() {
        var signatures: [[ScheduledNote]] = []
        for genre in Genre.allCases {
            let a = Self.loudRun(genre, steps: 256 + 6 * Self.bar, events: Self.busyLoud)
            let b = Self.loudRun(genre, steps: 256 + 6 * Self.bar, events: Self.busyLoud)
            #expect(a.notes == b.notes, "\(genre) is not deterministic")
            signatures.append(a.notes.filter { $0.step >= 256 })
        }
        for i in signatures.indices {
            for j in signatures.indices where j > i { #expect(signatures[i] != signatures[j]) }
        }
    }

    @Test func densityCapsHoldInEveryGenre() {
        let kinds: [TrafficEventKind] = [
            .dnsQuery, .dnsError, .tlsHello(serverName: "a.example"), .tcpSyn, .tcpRst, .retransmission,
            .icmpReply(rtt: 0.01),
            .icmpUnreachable, .multicastDiscovery, .newDestination(host: "x.example"), .newApp(bundleID: "app"),
            .newLANHost, .wifiEvent,
        ]
        let flood = Array((0..<12).map { _ in kinds }.joined())
        for genre in Genre.allCases {
            let r = Self.loudRun(genre, steps: Base.phrase * 6) { step in
                Base.traffic(bytesPerTick: step >= Base.phrase ? 2_500_000 : 0, events: flood)
            }
            #expect(r.sections.contains(.drop), "\(genre)")
            var perBar: [Int: [Instrument: Int]] = [:]
            var tapeStops: [Int: Int] = [:]
            for note in r.notes {
                perBar[note.step / Self.bar, default: [:]][note.instrument, default: 0] += 1
                if note.instrument == .tapeStop { tapeStops[note.step / Base.phrase, default: 0] += 1 }
            }
            for (index, counts) in perBar {
                for (instrument, cap) in DropConductor.eventCaps {
                    #expect(
                        counts[instrument, default: 0] <= cap,
                        "\(genre) \(instrument) x\(counts[instrument, default: 0]) in bar \(index)")
                }
                // Hats: base pattern (at most 16) plus 8 accents and two rolls of at most 5 hits.
                #expect(counts[.hat, default: 0] <= 16 + 8 + 10, "\(genre) hats in bar \(index)")
            }
            #expect(tapeStops.values.allSatisfy { $0 <= 1 })
        }
    }

    @Test func bassStaysInKeyInEveryGenre() {
        for genre in Genre.allCases {
            let r = Self.loudRun(genre, steps: 256 + 8 * Self.bar)
            for note in r.notes where note.instrument == .sub || note.instrument == .wobble || note.instrument == .keys
            {
                #expect(
                    r.inKey(note),
                    "\(genre) \(note.instrument) pitch \(note.params.pitch ?? 0) in \(r.tracks[note.step].keyName)")
            }
            for note in r.notes where note.instrument == .wobble {
                #expect(note.params.wobbleRate != nil && note.params.formant != nil && note.params.voice != nil)
            }
        }
    }

    // MARK: Signatures

    @Test func drumAndBassIsTwoStepAt174() {
        #expect(Genre.drumAndBass.defaultBPM == 174)
        let r = Self.loudRun(.drumAndBass, steps: 256 + 8 * Self.bar, events: Self.busyLoud)
        let drops = Self.dropBars(r)
        #expect(drops.count >= 8)
        for bar in Self.plainBars(drops) {
            // A song may play its backbeat at half time (narduk-libs#1617): the snare moves to 3.
            let snares = r.tracks[bar * Self.bar].halfTime ? [8] : [4, 12]
            #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.9) == snares, "snares in bar \(bar)")
            #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.5) == snares)
        }
        for bar in drops {
            #expect(Self.hits(r, .kick, bar: bar).contains(0) && Self.hits(r, .kick, bar: bar).contains(10))
        }
        let wobbles = r.notes.filter { $0.instrument == .wobble && r.sections[$0.step].isDrop }
        // Reese, in the app's character.
        #expect(wobbles.allSatisfy { ($0.params.voice ?? 0) % BassPatches.count == 1 })
        #expect(wobbles.allSatisfy { ($0.params.formant ?? 1) <= 0.35 })  // low formant
        #expect(wobbles.contains { $0.params.wobbleRate == .sixteenth })  // fast
        // Notes inside a bar touch end to start, so the engine glides between their pitches.
        for bar in Self.plainBars(drops) {
            let line = wobbles.filter { $0.step / Self.bar == bar }.sorted { $0.step < $1.step }
            #expect(line.count >= 2)
            for (a, b) in zip(line, line.dropFirst()) { #expect(a.step + a.params.lengthSteps == b.step) }
        }
        #expect(Set(wobbles.map { $0.params.pitch }).count >= 4)
    }

    @Test func houseKicksOnEveryBeat() {
        let r = Self.loudRun(.house, steps: 256 + 8 * Self.bar, events: Self.busyLoud)
        let drops = Self.dropBars(r)
        #expect(drops.count >= 8)
        for bar in Self.plainBars(drops) {
            for beat in [0, 4, 8, 12] {
                #expect(Self.hits(r, .kick, bar: bar).contains(beat), "no kick on step \(beat) of bar \(bar)")
            }
        }
        for bar in drops {
            let open = Self.hits(r, .openHat, bar: bar)
            #expect(open.count <= 2 && open.allSatisfy { $0 % 4 == 2 })  // upbeat open hats, within the cap
            // The bass pumps in the gaps between the kicks.
            let sub = Self.hits(r, .sub, bar: bar)
            #expect(sub.count >= 2 && sub.allSatisfy { $0 % 4 != 0 })
        }
        // Kicks carry through the build too.
        let build = r.notes.filter { $0.instrument == .kick && r.sections[$0.step] == .build }
        #expect(Set(build.map { $0.step % 4 }) == [0])
        #expect(build.count >= 4 * 8)
    }

    @Test func riddimIsSparseWithTripletWobbles() {
        let r = Self.loudRun(.riddim, steps: 256 + 8 * Self.bar)
        let drops = Self.dropBars(r)
        for bar in drops {
            #expect(Self.hits(r, .kick, bar: bar).contains(0) && Self.hits(r, .kick, bar: bar).count <= 2)
            #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.9).contains(8))
        }
        for bar in Self.plainBars(drops) { #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.5) == [8]) }
        let wobbles = r.notes.filter { $0.instrument == .wobble }
        #expect(wobbles.allSatisfy { [.eighthTriplet, .sixteenthTriplet].contains($0.params.wobbleRate) })
        #expect(wobbles.allSatisfy { ($0.params.voice ?? 0) % BassPatches.count == 5 })
        // Heavy sub: driven, and sounding for the whole bar.
        let sub = r.notes.filter { $0.instrument == .sub && r.sections[$0.step].isDrop }
        #expect(sub.allSatisfy { ($0.params.drive ?? 0) >= 0.9 && $0.velocity >= 0.95 })
        // Sparse: a handful of wobble hits a bar (bar fills may stutter), always one on the downbeat.
        for bar in drops { #expect(Self.hits(r, .wobble, bar: bar).contains(0)) }
        for bar in Self.plainBars(drops) {
            let hits = Self.hits(r, .wobble, bar: bar)
            #expect(hits.count <= 5, "bar \(bar): \(hits)")
        }
    }

    @Test func trapSlidesThe808AndRollsHatsOnDNSBursts() {
        let r = Self.loudRun(.trap, steps: 256 + 8 * Self.bar)
        let drops = Self.dropBars(r)
        #expect(!r.notes.contains { $0.instrument == .wobble })
        for bar in Self.plainBars(drops) {
            #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.9) == [8])
            let sub = r.notes.filter { $0.instrument == .sub && $0.step / Self.bar == bar }.sorted { $0.step < $1.step }
            #expect(sub.count >= 2)
            #expect(sub.allSatisfy { $0.params.glide != nil })
            // Legato: glides.
            for (a, b) in zip(sub, sub.dropFirst()) { #expect(a.step + a.params.lengthSteps == b.step) }
            #expect(sub.allSatisfy { (24...40).contains($0.params.pitch ?? 0) })
        }
        // The 808 hook moves: several pitches across the drop.
        let dropSub = r.notes.filter { $0.instrument == .sub && r.sections[$0.step].isDrop }
        #expect(Set(dropSub.map { $0.params.pitch }).count >= 3)
        // A DNS burst mid-drop rolls the hats on the steps that follow.
        let dnsA = TrafficEvent(time: 0, kind: .dnsQuery, direction: .outbound, app: nil)
        var c = Self.conductor(.trap)
        let before = Base.play(&c, steps: 256 + 3 * Self.bar + 5) { _ in Base.loud }
        c.ingest(TrafficBatch(events: [dnsA, dnsA, dnsA]))
        var after: [ScheduledNote] = []
        for step in (256 + 3 * Self.bar + 5)..<(256 + 3 * Self.bar + 5 + 12) { after += c.advance(throughStep: step) }
        #expect(!before.notes.isEmpty)
        let roll = after.filter { $0.instrument == .hat }.map(\.step)
        #expect(roll.count >= 5)
        #expect(zip(roll, roll.dropFirst()).contains { $1 - $0 == 1 })  // consecutive 16ths
        #expect(c.snapshot.legend.contains("hat roll ← DNS query burst"))
        // Rolls are bounded per bar.
        var capped = Self.conductor(.trap)
        let flood = Array(repeating: TrafficEventKind.dnsQuery, count: 20)
        let f = Base.play(&capped, steps: 256 + 6 * Self.bar) {
            Base.traffic(bytesPerTick: $0 > 20 ? 2_500_000 : 0, events: flood)
        }
        for bar in 0..<(f.sections.count / Self.bar) {
            #expect(f.notes.filter { $0.instrument == .hat && $0.step / Self.bar == bar }.count <= 16 + 8 + 10)
        }
    }

    @Test func chillIsSlowSoftAndChoppy() {
        let genre = Genre.chill
        #expect((85...90).contains(genre.defaultBPM))
        let r = Self.loudRun(genre, steps: 256 + 8 * Self.bar)
        let drops = Self.dropBars(r)
        for bar in drops {
            #expect(Self.hits(r, .kick, bar: bar, minVelocity: 0.8).isEmpty)  // sparse, soft kick
            #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.6).isEmpty)  // soft snare, fills included
        }
        for bar in Self.plainBars(drops) { #expect(Self.hits(r, .snare, bar: bar, minVelocity: 0.4) == [8]) }
        let wobbles = r.notes.filter { $0.instrument == .wobble }
        #expect(wobbles.allSatisfy { [.half, .quarter].contains($0.params.wobbleRate) })
        let vox = r.notes.filter { $0.instrument == .vox }
        #expect(!vox.isEmpty && vox.allSatisfy { $0.velocity <= 0.4 })
        #expect(r.notes.contains { $0.instrument == .riser && $0.velocity < 0.5 })
    }

    // MARK: Live switching

    /// Plays both conductors through `through` steps, then returns the notes of each from `from` to `to`.
    static func continuePlaying(_ c: inout DropConductor, from: Int, to: Int) -> [ScheduledNote] {
        var notes: [ScheduledNote] = []
        for step in from..<to {
            c.ingest(Base.loud)
            notes += c.advance(throughStep: step)
        }
        return notes
    }

    @Test func aMidSongSwitchLandsExactlyAtTheNextBar() {
        let boundary = 256 + 3 * Self.bar  // a bar line inside the first drop
        let askedAt = boundary - 6  // six steps of the bar already emitted
        var control = Self.conductor(.dubstep)
        var live = Self.conductor(.dubstep)
        let head = Base.play(&control, steps: askedAt, batch: { _ in Base.loud })
        let liveHead = Base.play(&live, steps: askedAt, batch: { _ in Base.loud })
        #expect(head.notes == liveHead.notes)
        #expect(live.pendingGenre == nil)

        live.setGenre(.drumAndBass)
        #expect(live.pendingGenre == .drumAndBass)
        #expect(live.activeGenre == .dubstep)
        #expect(live.lastSwitch == nil)
        let end = boundary + 4 * Self.bar
        let a = Self.continuePlaying(&control, from: askedAt, to: end)
        let b = Self.continuePlaying(&live, from: askedAt, to: end)

        // Nothing emitted earlier changes, and the steps before the bar line differ only by the transition.
        let beforeA = a.filter { $0.step < boundary }
        let beforeB = b.filter { $0.step < boundary }
        let lead = beforeB.filter { !beforeA.contains($0) }
        #expect(beforeB.filter { beforeA.contains($0) } == beforeA)
        #expect(lead.count == 1)
        #expect(lead[0].instrument == .tapeStop)  // a drop: tape stop into the switch
        #expect(lead[0].step + lead[0].params.lengthSteps == boundary)
        #expect(lead[0].params.lengthSteps <= Self.bar)

        // From the bar line on it is a different song, in the same section.
        let afterA = a.filter { $0.step >= boundary }
        let afterB = b.filter { $0.step >= boundary }
        #expect(afterA != afterB)
        #expect(afterB.contains { $0.step == boundary && $0.instrument == .impact })
        for barIndex in (boundary / Self.bar)..<(end / Self.bar) {
            let snares = afterB.filter {
                $0.instrument == .snare && $0.velocity >= 0.9 && $0.step / Self.bar == barIndex
            }.map { $0.step % Self.bar }
            #expect(snares == [4, 12], "bar \(barIndex)")
        }
        #expect(afterA.contains { $0.instrument == .snare && $0.step % Self.bar == 8 })
        #expect(live.snapshot.section == control.snapshot.section)
        #expect(abs(live.snapshot.energy - control.snapshot.energy) < 0.1)

        // The tempo changed from the bar line on, and the conductor says so.
        #expect(live.pendingGenre == nil && live.activeGenre == .drumAndBass)
        #expect(live.lastSwitch == GenreSwitch(genre: .drumAndBass, step: boundary, bpm: 174))
        #expect(live.settings.bpm == 174 && live.settings.genre == .drumAndBass)
        #expect(live.snapshot.legend.contains("genre ← DnB, 174 BPM"))

        // No step is missing or repeated across the boundary.
        #expect(b.map(\.step) == b.map(\.step).sorted())
        #expect(Set(b.map(\.step)).isSubset(of: Set(askedAt..<end)))
        #expect(Set(afterB.map(\.step)).contains(boundary) && Set(afterB.map(\.step)).contains(boundary + 4))
    }

    @Test func switchingStepByStepNeverReEmitsOrSkips() {
        var live = Self.conductor(.dubstep)
        var steps: [Int: [ScheduledNote]] = [:]
        for step in 0..<(256 + 8 * Self.bar) {
            if step == 256 + 2 * Self.bar + 3 { live.setGenre(.house) }
            if step == 256 + 5 * Self.bar + 9 { live.settings.genre = .chill }  // the property route works too
            live.ingest(Base.loud)
            for note in live.advance(throughStep: step) { steps[note.step, default: []].append(note) }
        }
        #expect(steps.keys.allSatisfy { $0 >= 0 })
        #expect(steps.keys.max()! < 256 + 8 * Self.bar)
        let houseBar = (256 + 3 * Self.bar) / Self.bar
        let chillBar = (256 + 6 * Self.bar) / Self.bar
        func kicks(_ bar: Int) -> [Int] {
            steps.filter { $0.key / Self.bar == bar }.flatMap(\.value).filter { $0.instrument == .kick }.map {
                $0.step % Self.bar
            }.sorted()
        }
        #expect(kicks(houseBar - 1) != [0, 4, 8, 12])
        #expect(Set([0, 4, 8, 12]).isSubset(of: kicks(houseBar)))
        #expect(Set([0, 4, 8, 12]).isSubset(of: kicks(chillBar - 1)))
        #expect(!kicks(chillBar).contains(4))
        #expect(live.settings.bpm == 88)
    }

    @Test func aRequestOnTheBarLineSwitchesThere() {
        var c = Self.conductor(.dubstep)
        _ = Base.play(&c, steps: 256 + 2 * Self.bar, batch: { _ in Base.loud })  // next step to emit is a bar line
        c.setGenre(.house)
        let notes = Self.continuePlaying(&c, from: 256 + 2 * Self.bar, to: 256 + 3 * Self.bar)
        #expect(notes.filter { $0.instrument == .kick }.map { $0.step % Self.bar } == [0, 4, 8, 12])
        #expect(notes.contains { $0.step == 256 + 2 * Self.bar && $0.instrument == .impact })
        #expect(c.lastSwitch?.step == 256 + 2 * Self.bar)
    }

    @Test func changingYourMindBeforeTheBarLineSwitchesNothing() {
        var control = Self.conductor(.dubstep)
        var c = Self.conductor(.dubstep)
        _ = Base.play(&control, steps: 256 + 40, batch: { _ in Base.loud })
        _ = Base.play(&c, steps: 256 + 40, batch: { _ in Base.loud })
        c.setGenre(.trap)
        #expect(c.pendingGenre == .trap)
        c.setGenre(.dubstep)
        #expect(c.pendingGenre == nil)
        let a = Self.continuePlaying(&control, from: 256 + 40, to: 256 + 80)
        let b = Self.continuePlaying(&c, from: 256 + 40, to: 256 + 80)
        #expect(a == b)
        #expect(c.lastSwitch == nil && c.settings.bpm == 140)
    }

    @Test func outsideADropTheTransitionIsARiser() {
        var c = Self.conductor(.dubstep)
        _ = Base.play(&c, steps: 40, batch: { _ in Base.quiet })  // intro, mid-bar (step 40 = bar 2, step 8)
        c.setGenre(.chill)
        let notes = Self.continuePlaying(&c, from: 40, to: 64)
        let riser = notes.first { $0.instrument == .riser }
        #expect(riser?.step == 40 && riser?.params.lengthSteps == 8)
        #expect(notes.contains { $0.step == 48 && $0.instrument == .impact })
        #expect(c.settings.bpm == 88 && c.snapshot.section == .intro)
    }

    @Test func aGenreChosenBeforeTheFirstStepNeedsNoTransition() {
        var c = Self.conductor(.dubstep)
        c.setGenre(.drumAndBass)
        let notes = c.advance(throughStep: 31)
        #expect(!notes.contains { $0.instrument == .impact || $0.instrument == .riser || $0.instrument == .tapeStop })
        #expect(c.settings.bpm == 174 && c.lastSwitch == GenreSwitch(genre: .drumAndBass, step: 0, bpm: 174))
    }

    @Test func transitionsRespectTheDensityCaps() {
        let flood = Array(repeating: TrafficEventKind.tcpRst, count: 12) + Array(repeating: .icmpUnreachable, count: 12)
        var c = Self.conductor(.dubstep)
        var notes: [ScheduledNote] = []
        let genres: [Genre] = [
            .trap, .house, .drumAndBass, .riddim, .chill, .dubstep, .techno, .ukGarage, .synthwave, .lofi, .rock,
            .folk, .funk,
        ]
        for step in 0..<(256 + 12 * Self.bar) {
            if step >= 256, (step - 256) % (Self.bar * 2) == 5 {
                c.setGenre(genres[((step - 256) / (Self.bar * 2)) % genres.count])
            }
            c.ingest(Base.traffic(bytesPerTick: 2_500_000, events: flood))
            notes += c.advance(throughStep: step)
        }
        var perBar: [Int: [Instrument: Int]] = [:]
        var tapeStops: [Int: Int] = [:]
        for note in notes {
            perBar[note.step / Self.bar, default: [:]][note.instrument, default: 0] += 1
            if note.instrument == .tapeStop { tapeStops[note.step / Base.phrase, default: 0] += 1 }
        }
        for (index, counts) in perBar {
            for (instrument, cap) in DropConductor.eventCaps {
                #expect(counts[instrument, default: 0] <= cap, "\(instrument) in bar \(index)")
            }
        }
        #expect(tapeStops.values.allSatisfy { $0 <= 1 })
        #expect(c.lastSwitch != nil)
    }
}
