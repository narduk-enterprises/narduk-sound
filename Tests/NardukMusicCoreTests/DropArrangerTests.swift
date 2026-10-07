import Foundation
import Testing

@testable import NardukMusicCore

/// The DROP made out of the song under it (narduk-libs B8-drops): its own notes, in its key, on the downbeat,
/// deterministic, varied by seed and variety, and different for two songs of one genre.
@Suite struct DropArrangerTests {
    /// A context for a real song: a conductor plays a few bars, and the drop's material is read off it.
    static func context(
        _ genre: Genre, seed: UInt64 = 0x5EED, variety: Double = 0.75, dropNumber: Int = 0
    ) -> DropContext {
        var settings = SongSettings(genre: genre, seed: seed, variety: variety)
        settings.bpm = genre.defaultBPM
        var conductor = DropConductor(settings: settings)
        _ = conductor.advance(throughStep: 63)
        let sps = settings.secondsPerStep
        let key = DropArranger.parseKey(conductor.snapshot.track?.key ?? "") ?? (pitchClass: 5, minor: true)
        let tonic = 60 + key.pitchClass
        return DropContext(
            genre: genre, keyRoot: tonic, minor: key.minor, chordRoot: tonic, nextChordRoot: tonic + 5,
            secondsPerStep: sps, seed: seed, variety: variety, dropNumber: dropNumber,
            material: DropMaterial.capture(from: conductor))
    }

    static func dropNotes(_ c: DropContext, bars: Int = 4, charge: Double = 1) -> [ScheduledNote] {
        (0..<(bars * c.stepsPerBar)).flatMap {
            DropArranger.drop(position: $0, step: 1_000 + $0, power: 1, charge: charge, context: c)
        }
    }

    static func buildNotes(_ c: DropContext, steps: Int = 80, from first: Int = 0) -> [ScheduledNote] {
        (first..<(first + steps)).flatMap { DropArranger.build(step: 500 + $0, heldSteps: $0, context: c) }
    }

    static let pitched: Set<Instrument> = [
        .wobble, .sub, .keys, .strum, .electricStrum, .bassGuitar, .acousticGuitar, .electricGuitar, .riser,
    ]

    /// Pitch classes of the song's own bass and hook, relative to its tonic.
    static func songClasses(_ c: DropContext) -> Set<Int> {
        guard let m = c.material else { return [] }
        return Set(
            (m.current.all + m.drop.all).compactMap { $0.params.pitch.map { (($0 - c.keyRoot) % 12 + 12) % 12 } })
    }

    @Test(arguments: Genre.allCases) func everyPitchedNoteIsInTheSongsKey(genre: Genre) {
        let c = Self.context(genre)
        let scale = Set(DropArranger.scale(c))
        #expect(scale.count >= 5)
        for note in Self.dropNotes(c) + Self.buildNotes(c) where Self.pitched.contains(note.instrument) {
            guard let pitch = note.params.pitch else { continue }
            let rel = ((pitch - c.keyRoot) % 12 + 12) % 12
            #expect(scale.contains(rel), "\(genre): \(note.instrument) \(pitch) is out of the song's key")
        }
    }

    @Test(arguments: Genre.allCases) func theDropIsMadeOfTheSongsOwnNotes(genre: Genre) throws {
        let c = Self.context(genre)
        let material = try #require(c.material)
        #expect(!material.drop.bass.isEmpty || !material.drop.drums.isEmpty, "\(genre): nothing captured")
        let notes = Self.dropNotes(c, bars: 2)
        // Each pitch the song's drop bass plays sounds in the drop, in the song's own instrument.
        for source in material.drop.bass {
            guard let pitch = source.params.pitch, c.genre != .dubstep, c.genre != .riddim else { continue }
            #expect(
                notes.contains { $0.instrument == source.instrument && $0.params.pitch == pitch },
                "\(genre): the song's bass \(source.instrument) \(pitch) is missing from the drop")
        }
        // Its drums keep their rhythm: every kick of the song's drop groove lands on the same step (half-time stretches).
        if c.genre != .dubstep, c.genre != .riddim {
            for kick in material.drop.drums where kick.instrument == .kick {
                let at = notes.filter { $0.instrument == .kick && $0.step == 1_000 + kick.step }
                #expect(!at.isEmpty, "\(genre): the song's kick at \(kick.step) is gone")
            }
        }
    }

    @Test(arguments: Genre.allCases) func theDropLandsOnTheDownbeatWithTheChord(genre: Genre) {
        let c = Self.context(genre)
        let first = DropArranger.drop(position: 0, step: 7, power: 1, charge: 1, context: c)
        #expect(first.allSatisfy { $0.step == 7 })
        #expect(first.filter { $0.instrument == .keys }.count >= 3, "\(genre) has no chord on the downbeat")
        let big = first.filter { [.impact, .kick, .sub, .wobble, .bassGuitar, .tapeStop].contains($0.instrument) }
        #expect(!big.isEmpty, "\(genre) has nothing big on the downbeat")
        // The next bar moves to the next chord's root.
        let second = DropArranger.drop(position: c.stepsPerBar, step: 9, power: 1, charge: 1, context: c)
        let roots = second.filter { $0.instrument == .keys }.compactMap { $0.params.pitch }.map { $0 % 12 }
        #expect(roots.contains((c.nextChordRoot ?? c.chordRoot) % 12), "\(genre) stays on the tonic")
    }

    @Test(arguments: Genre.allCases) func theRiserEndsOnTheTonic(genre: Genre) throws {
        let c = Self.context(genre)
        let riser = try #require(
            DropArranger.build(step: 0, heldSteps: 0, context: c).first { $0.instrument == .riser })
        #expect(try #require(riser.params.pitch) % 12 == c.keyRoot % 12)
        #expect(riser.params.lengthSteps == DropArranger.riserSteps(secondsPerStep: c.secondsPerStep))
        #expect(DropArranger.build(step: 1, heldSteps: 1, context: c).allSatisfy { $0.instrument != .riser })
    }

    @Test(arguments: Genre.allCases) func aDropIsDeterministicPerSeed(genre: Genre) {
        let a = Self.dropNotes(Self.context(genre, seed: 9)) + Self.buildNotes(Self.context(genre, seed: 9))
        let b = Self.dropNotes(Self.context(genre, seed: 9)) + Self.buildNotes(Self.context(genre, seed: 9))
        #expect(a == b)
    }

    @Test(arguments: [Genre.dubstep, .rock, .house, .trap, .synthwave, .lofi, .drumAndBass])
    func twoSongsOfOneGenreDropDifferently(genre: Genre) {
        let a = Self.context(genre, seed: 11)
        let b = Self.context(genre, seed: 29)
        let content = { (c: DropContext) in
            Self.dropNotes(c).map { "\($0.step - 1_000)/\($0.instrument)/\($0.params.pitch ?? -1)/\($0.velocity)" }
        }
        #expect(content(a) != content(b), "\(genre): different songs dropped identically")
        #expect(a.material != b.material)
    }

    @Test func varietyZeroAlwaysPlaysTheFirstTreatmentAndOneReachesAll() {
        var seen: Set<Int> = []
        for n in 0..<200 {
            #expect(DropArranger.variant(Self.context(.dubstep, variety: 0, dropNumber: n)) == 0)
            seen.insert(DropArranger.variant(Self.context(.dubstep, variety: 1, dropNumber: n)))
        }
        #expect(seen == Set(0..<DropArranger.variantCount))
    }

    @Test func repeatedDropsDifferWhenVarietyIsOn() {
        let notes = (0..<12).map { Self.dropNotes(Self.context(.rock, variety: 1, dropNumber: $0), bars: 2) }
        #expect(Set(notes.map { $0.map { "\($0.instrument)\($0.params.pitch ?? 0)" } }).count > 1)
    }

    @Test func theBuildStuttersFasterAsItChargesAndHoldsOnceFull() {
        let c = Self.context(.rock)
        let sps = c.secondsPerStep
        let full = Int((DropArranger.fullChargeSeconds / sps).rounded(.up)) + 1
        func hits(_ from: Int, _ count: Int) -> Int {
            Self.buildNotes(c, steps: count, from: from).filter { $0.instrument == .snare }.count
        }
        let early = hits(Int((0.21 * DropArranger.fullChargeSeconds / sps).rounded(.up)), 4)
        let middle = hits(Int((0.36 * DropArranger.fullChargeSeconds / sps).rounded(.up)), 4)
        let late = hits(full, 4)
        #expect(early < middle && middle < late, "the roll does not speed up: \(early) \(middle) \(late)")
        // Past the full charge nothing accelerates: the shape of a step does not depend on how long the hold has gone on.
        let shape = { (held: Int) in
            DropArranger.build(step: 0, heldSteps: held, context: c).map {
                "\($0.instrument)/\($0.params.pitch ?? -1)/\($0.params.delay ?? 0)"
            }
        }
        #expect(shape(full + 40) == shape(full + 41))
        #expect(shape(full + 40) == shape(full + 400))
    }

    @Test func theHookClimbsTheSongsScaleAsTheBuildCharges() throws {
        let c = Self.context(.rock)
        let sps = c.secondsPerStep
        func hookPitches(charge: Double) -> [Int] {
            let at = Int(charge * DropArranger.fullChargeSeconds / sps)
            return Self.buildNotes(c, steps: 32, from: at).filter { DropGroove.hookInstruments.contains($0.instrument) }
                .compactMap(\.params.pitch)
        }
        let low = hookPitches(charge: 0.05)
        let high = hookPitches(charge: 1)
        try #require(!low.isEmpty && !high.isEmpty)
        #expect(high.reduce(0, +) / high.count > low.reduce(0, +) / low.count)
    }

    @Test func genreBiasesTheMovesWithoutReplacingTheSong() {
        // Lofi lands softly: no impact, a tape stop; rock crashes; both still play the song's own bass.
        let lofi = Self.dropNotes(Self.context(.lofi, variety: 0), bars: 1)
        #expect(lofi.allSatisfy { $0.instrument != .impact })
        #expect(lofi.contains { $0.instrument == .tapeStop })
        let rock = Self.dropNotes(Self.context(.rock, variety: 0), bars: 1)
        #expect(rock.contains { $0.instrument == .openHat && $0.step == 1_000 })
        #expect(rock.contains { $0.instrument == .impact })
        // Dubstep plays the song's drop at half speed over two bars: the second bar is not a repeat of the first.
        let dub = Self.context(.dubstep)
        let first = DropArranger.drop(position: 0, step: 0, power: 1, charge: 1, context: dub)
        let second = DropArranger.drop(position: dub.stepsPerBar, step: 0, power: 1, charge: 1, context: dub)
        #expect(!first.isEmpty && !second.isEmpty)
    }

    @Test func intensityScalesWithTheHold() {
        let c = Self.context(.house)
        let weak = Self.dropNotes(c, bars: 1, charge: 0).filter { $0.instrument == .impact }.map(\.velocity).max() ?? 0
        let strong =
            Self.dropNotes(c, bars: 1, charge: 1).filter { $0.instrument == .impact }.map(\.velocity).max() ?? 0
        #expect(strong > weak)
    }

    @Test func aSongWithNoNotesToHandStillDrops() {
        let c = DropContext(genre: .trap, keyRoot: 65, minor: true, secondsPerStep: 0.1)
        #expect(!Self.dropNotes(c, bars: 1).isEmpty)
        #expect(!Self.buildNotes(c).isEmpty)
    }

    @Test func parsesAKeyName() {
        #expect(DropArranger.parseKey("F# dorian")?.pitchClass == 6)
        #expect(DropArranger.parseKey("F# dorian")?.minor == true)
        #expect(DropArranger.parseKey("Bb major")?.pitchClass == 10)
        #expect(DropArranger.parseKey("Bb major")?.minor == false)
        #expect(DropArranger.parseKey("?") == nil)
    }
}

@Suite struct DropFilterSweepTests {
    static let sps = 60 / 140.0 / 4

    @Test(arguments: Genre.allCases) func theSweepStartsOpenRisesAndHoldsOnceFull(genre: Genre) {
        let full = Int((DropArranger.fullChargeSeconds / Self.sps).rounded(.up))
        #expect(DropArranger.filterSweep(heldSteps: 0, secondsPerStep: Self.sps, genre: genre).isIdle)
        var last: Float = 0
        for held in 1...(full + 30) {
            let f = DropArranger.filterSweep(heldSteps: held, secondsPerStep: Self.sps, genre: genre)
            #expect(f.highPassHz >= last, "\(genre): the high-pass fell at \(held)")
            #expect(f.highPassHz.isFinite && f.highPassHz <= 3_000)
            #expect(f.lowPassHz == MasterFilter.lowPassOpen)
            last = f.highPassHz
        }
        // Full charge: it holds exactly where it is, however long the hold goes on.
        let a = DropArranger.filterSweep(heldSteps: full, secondsPerStep: Self.sps, genre: genre)
        #expect(a == DropArranger.filterSweep(heldSteps: full + 400, secondsPerStep: Self.sps, genre: genre))
        #expect(a.highPassHz > 500, "\(genre): the build barely closes the low end")
    }

    @Test func theSweepAcceleratesAndGentleGenresStayLower() {
        let full = Int((DropArranger.fullChargeSeconds / Self.sps).rounded(.up))
        func hz(_ fraction: Double, _ genre: Genre) -> Float {
            DropArranger.filterSweep(heldSteps: Int(Double(full) * fraction), secondsPerStep: Self.sps, genre: genre)
                .highPassHz
        }
        // Exponential in the charge: the last quarter climbs further than the first three quarters' last quarter.
        #expect(hz(1, .house) - hz(0.75, .house) > hz(0.5, .house) - hz(0.25, .house))
        #expect(hz(1, .lofi) < hz(1, .house))
        #expect(hz(1, .rock) < hz(1, .house))
    }

    @Test func theFilterSettingIsSanitised() {
        let f = MasterFilter(highPassHz: .nan, lowPassHz: -5, resonance: 9)
        #expect(f.highPassHz == MasterFilter.highPassOpen && f.lowPassHz == 60 && f.resonance == 0.9)
        #expect(
            MasterFilter.idle.isIdle && !MasterFilter(highPassHz: 400).isIdle && !MasterFilter(lowPassHz: 900).isIdle)
    }
}
