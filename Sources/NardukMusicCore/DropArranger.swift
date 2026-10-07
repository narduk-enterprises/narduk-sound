import Foundation

// The DROP button's sound, made out of the song that is playing (narduk-libs B8-drops). A press starts a build, a hold
// keeps it at full charge and a release lands the drop; this file writes the notes of both, one step at a time, as pure
// functions of a `DropContext`. The notes, timbres and rhythms are the song's own, taken from a `DropMaterial` (one bar
// of its current groove and one of its drop section's groove, captured from the conductor), so two songs in the same
// genre drop differently. Genre only biases how hard each move is (`Bias`): half-time for dubstep, a tape stop for lofi.
//
// - Build: the song's last bar loops and then its last half-bar, and the loop stutters down the note values (1/4,
//   1/8, 1/16, 1/32) as the charge fills; the hook climbs the song's own scale; the song's snare (or hat) rolls at
//   its tempo; a riser sweeps up to the tonic. Once the charge is full the stutter holds where it is until the release.
// - Drop: the song's drop section lands on the downbeat with its own drums and bass at full energy: the bass is
//   layered with a sub an octave down and driven harder, the hook goes up an octave or is harmonised in the key, and
//   the chord lands with it (the next chord on the bar after).
// - Variety: `SongSettings.variety` is the chance that a drop picks one of its three hook treatments instead of the
//   first; the seed and the drop's number pick which, so repeated drops differ. Variety 0 always plays the first.

/// One bar of what the song plays, split by role. Steps are offsets in the bar (0 ..< `stepsPerBar`).
public struct DropGroove: Sendable, Hashable {
    public var drums: [ScheduledNote] = []
    public var bass: [ScheduledNote] = []
    public var hook: [ScheduledNote] = []

    public init(drums: [ScheduledNote] = [], bass: [ScheduledNote] = [], hook: [ScheduledNote] = []) {
        self.drums = drums
        self.bass = bass
        self.hook = hook
    }

    public var isEmpty: Bool { drums.isEmpty && bass.isEmpty && hook.isEmpty }
    var all: [ScheduledNote] { drums + bass + hook }

    static let drumInstruments: Set<Instrument> = [.kick, .snare, .hat, .openHat]
    static let bassInstruments: Set<Instrument> = [.wobble, .sub, .bassGuitar]
    static let hookInstruments: Set<Instrument> = [
        .keys, .vox, .acousticGuitar, .electricGuitar, .strum, .electricStrum,
    ]

    /// The groove of the bar starting at `barStart` in `notes`, its steps made relative to the bar.
    public init(notes: [ScheduledNote], barStart: Int, stepsPerBar: Int) {
        for note in notes where note.step >= barStart && note.step < barStart + stepsPerBar {
            var local = note
            local.step -= barStart
            if Self.drumInstruments.contains(note.instrument) {
                drums.append(local)
            } else if Self.bassInstruments.contains(note.instrument) {
                bass.append(local)
            } else if Self.hookInstruments.contains(note.instrument) {
                hook.append(local)
            }
        }
    }
}

/// What the song plays now and what its drop section plays, captured from the conductor.
public struct DropMaterial: Sendable, Hashable {
    public var stepsPerBar: Int
    /// The song's groove as it is playing.
    public var current: DropGroove
    /// The groove of the song's drop section (the current one when the song is in a drop, or when no drop could be found).
    public var drop: DropGroove

    public init(stepsPerBar: Int = 16, current: DropGroove, drop: DropGroove? = nil) {
        self.stepsPerBar = stepsPerBar
        self.current = current
        self.drop = drop.flatMap { $0.isEmpty ? nil : $0 } ?? current
    }

    /// Reads the song off a copy of `conductor` (the live one is untouched): the next whole bar of what it is playing,
    /// and the first whole bar of the drop section it lands when one is forced. Deterministic; call it when the DROP
    /// is pressed, off the audio thread.
    public static func capture(from conductor: DropConductor, stepsPerBar: Int = 16) -> DropMaterial {
        let spb = max(4, stepsPerBar)
        var now = conductor
        let start = ((conductor.snapshot.step + 1) / spb + 1) * spb
        _ = now.advance(throughStep: start - 1)
        let current = DropGroove(notes: now.advance(throughStep: start + spb - 1), barStart: start, stepsPerBar: spb)

        var next = conductor
        next.queueDrop()
        var cursor = start
        _ = next.advance(throughStep: cursor - 1)
        var dropGroove = DropGroove()
        for _ in 0..<24 {
            _ = next.advance(throughStep: cursor + spb - 1)
            cursor += spb
            if next.snapshot.section.isDrop {
                dropGroove = DropGroove(
                    notes: next.advance(throughStep: cursor + spb - 1), barStart: cursor, stepsPerBar: spb)
                break
            }
        }
        return DropMaterial(stepsPerBar: spb, current: current, drop: dropGroove)
    }

    /// A plain groove on the tonic, for a song whose notes are not to hand.
    public static func plain(keyRoot: Int, stepsPerBar: Int = 16) -> DropMaterial {
        func note(_ step: Int, _ instrument: Instrument, _ velocity: Double, pitch: Int? = nil) -> ScheduledNote {
            ScheduledNote(step: step, instrument: instrument, velocity: velocity, params: NoteParams(pitch: pitch))
        }
        let half = stepsPerBar / 2
        let groove = DropGroove(
            drums: [
                note(0, .kick, 1), note(half, .kick, 0.9), note(stepsPerBar / 4, .snare, 0.9),
                note(stepsPerBar * 3 / 4, .snare, 0.9),
            ] + stride(from: 0, to: stepsPerBar, by: 2).map { note($0, .hat, 0.4) },
            bass: [note(0, .sub, 0.9, pitch: keyRoot - 24), note(half, .sub, 0.8, pitch: keyRoot - 24)],
            hook: [])
        return DropMaterial(stepsPerBar: stepsPerBar, current: groove)
    }
}

/// What a drop needs to know about the song playing under it.
public struct DropContext: Sendable, Hashable {
    public var genre: Genre
    /// MIDI tonic of the key, in any octave.
    public var keyRoot: Int
    public var minor: Bool
    /// The song's current chord root (its bass line's latest root), MIDI, in any octave.
    public var chordRoot: Int
    /// The next chord's root, when the song knows it; the drop moves to it on its second bar. Nil holds the current one.
    public var nextChordRoot: Int?
    public var stepsPerBar: Int
    public var secondsPerStep: Double
    public var seed: UInt64
    /// 0 ... 1, `SongSettings.variety`.
    public var variety: Double
    /// How many drops this song has played, so the next one can differ from the last.
    public var dropNumber: Int
    /// The song's wobble patch (`NoteParams.voice`), so the drop's bass is the song's bass.
    public var bassVoice: Int?
    /// The song's own notes (`DropMaterial.capture`); nil plays a plain groove on the tonic.
    public var material: DropMaterial?

    public init(
        genre: Genre, keyRoot: Int, minor: Bool, chordRoot: Int? = nil, nextChordRoot: Int? = nil,
        stepsPerBar: Int = 16, secondsPerStep: Double, seed: UInt64 = 0x5EED, variety: Double = 0.75,
        dropNumber: Int = 0, bassVoice: Int? = nil, material: DropMaterial? = nil
    ) {
        self.genre = genre
        self.keyRoot = keyRoot
        self.minor = minor
        self.chordRoot = chordRoot ?? keyRoot
        self.nextChordRoot = nextChordRoot
        self.stepsPerBar = max(4, stepsPerBar)
        self.secondsPerStep = max(secondsPerStep, 0.001)
        self.seed = seed
        self.variety = min(1, max(0, variety.isFinite ? variety : 0))
        self.dropNumber = dropNumber
        self.bassVoice = bassVoice
        self.material = material
    }
}

public enum DropArranger {
    /// Seconds of holding that fill the charge: the build stops getting faster here and holds flat until the release.
    public static let fullChargeSeconds = 4.0

    /// 0 ... 1: how long the build has run.
    public static func charge(heldSteps: Int, secondsPerStep: Double) -> Double {
        min(1, max(0, Double(heldSteps) * secondsPerStep / fullChargeSeconds))
    }

    /// How long the riser lasts, in steps: it tops out as the charge fills, however long the hold goes on.
    public static func riserSteps(secondsPerStep: Double) -> Int {
        max(1, Int((fullChargeSeconds / secondsPerStep).rounded()))
    }

    /// The tonic (a pitch class, 0 = C) and quality of a key as `TrackInfo.key` names it ("F# dorian", "Bb major"):
    /// minor for the aeolian, dorian, phrygian and locrian modes, major otherwise. Nil if the tonic does not parse.
    public static func parseKey(_ key: String) -> (pitchClass: Int, minor: Bool)? {
        let words = key.split(separator: " ")
        guard let name = words.first, let letter = name.first else { return nil }
        let base: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitchClass = base[Character(letter.uppercased())] else { return nil }
        for accidental in name.dropFirst() {
            if accidental == "#" || accidental == "♯" { pitchClass += 1 }
            if accidental == "b" || accidental == "♭" { pitchClass -= 1 }
        }
        let mode = words.dropFirst().joined(separator: " ").lowercased()
        let minor = ["minor", "aeolian", "dorian", "phrygian", "locrian"].contains { mode.contains($0) }
        return ((pitchClass % 12 + 12) % 12, minor)
    }

    // MARK: Variants

    /// How many hook treatments a drop has: the hook an octave up, harmonised a third above, or doubled up an octave
    /// and a fifth.
    public static let variantCount = 3

    /// Which treatment this drop plays: always 0 at variety 0, otherwise decided by the seed and the drop's number.
    public static func variant(_ c: DropContext) -> Int {
        guard c.variety > 0 else { return 0 }
        var rng = MusicRNG(seed: c.seed ^ StableHash.fnv1a("drop/\(c.genre.rawValue)/\(c.dropNumber)"))
        guard rng.unit() < c.variety else { return 0 }
        return Int(rng.next() % UInt64(variantCount))
    }

    // MARK: Genre bias

    /// How hard each move is for a genre. The material is the song's; this only shapes how it is played.
    struct Bias {
        /// 2 plays the drop at half speed over two bars (half-time).
        var stretch = 1
        /// The impact's loudness at the downbeat; 0 leaves it out.
        var impact = 1.0
        /// Drive added to the bass in the drop.
        var drive = 0.25
        /// Layer a sub an octave under every bass note.
        var layerSub = true
        var tapeStop = false
        var crash = false
        var fourOnFloor = false
        var gatedSnare = false
        var arpeggio = false
        var hatRoll = false
        var breakRoll = false
        /// Everything in the drop is softer by this factor.
        var gain = 1.0
    }

    static func bias(_ genre: Genre) -> Bias {
        var b = Bias()
        switch genre {
        case .dubstep: b.stretch = 2
        case .riddim: b.stretch = 2
        case .drumAndBass: b.breakRoll = true
        case .trap: b.hatRoll = true
        case .house, .techno: b.fourOnFloor = true
        case .ukGarage: b.impact = 0.8
        case .chill, .lofi:
            b.impact = 0
            b.drive = 0
            b.tapeStop = true
            b.gain = 0.65
        case .rock, .folk, .funk:
            b.crash = true
            b.layerSub = false
            b.impact = 0.5
        case .synthwave:
            b.gatedSnare = true
            b.arpeggio = true
            b.impact = 0.8
        }
        return b
    }

    // MARK: Build

    /// The notes of the build at `step`, `heldSteps` after the press (0 is the press). Everything rides the charge, which
    /// stops at 1: the stutter and the roll hold where they are until the release.
    public static func build(step: Int, heldSteps: Int, context c: DropContext) -> [ScheduledNote] {
        let charge = charge(heldSteps: heldSteps, secondsPerStep: c.secondsPerStep)
        let material = c.material ?? DropMaterial.plain(keyRoot: c.keyRoot, stepsPerBar: c.stepsPerBar)
        // A part the song is not playing yet (an intro without a hook) is borrowed from its drop section.
        let groove = DropGroove(
            drums: material.current.drums.isEmpty ? material.drop.drums : material.current.drums,
            bass: material.current.bass.isEmpty ? material.drop.bass : material.current.bass,
            hook: material.current.hook.isEmpty ? material.drop.hook : material.current.hook)
        let spb = material.stepsPerBar
        let scale = scale(c)
        let bias = bias(c.genre)
        var out: [ScheduledNote] = []
        func add(_ note: ScheduledNote, at delay: Double? = nil) {
            var n = note
            n.step = step
            if let delay { n.params.delay = delay }
            out.append(n)
        }
        func make(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) -> ScheduledNote {
            ScheduledNote(step: step, instrument: instrument, velocity: min(1, velocity), params: params)
        }

        if heldSteps == 0 {
            // The riser sweeps two octaves up from the tonic's pitch class, so it ends on the tonic.
            add(
                make(
                    .riser, bias.impact == 0 ? 0.4 : 0.9,
                    NoteParams(
                        pitch: fold(c.keyRoot, 40...51), lengthSteps: riserSteps(secondsPerStep: c.secondsPerStep))
                ))
        }

        // The loop: the song's last bar, then its last half-bar, then a slice that retriggers every 1/4, 1/8, 1/16 and
        // finally 1/32 of a beat as the charge fills.
        let span: Int
        switch charge {
        case ..<0.2: span = spb
        case ..<0.35: span = spb / 2
        case ..<0.5: span = 4
        case ..<0.7: span = 2
        default: span = 1
        }
        let thirtySeconds = charge >= 0.85
        let rise = Int((charge * Double(scale.count)).rounded())
        let heard = 0.5 + 0.5 * charge
        let loop = groove.bass + groove.hook
        if span >= spb / 2 {
            // Replay the last `span` steps of the bar, over and over.
            let window = spb - span
            let position = window + heldSteps % span
            for note in loop where note.step == position {
                var n = note
                if Self.isHook(n) { n.params.pitch = n.params.pitch.map { transpose($0, by: rise, c, scale) } }
                n.velocity = min(1, n.velocity * heard)
                add(n)
            }
        } else {
            // A slice: the notes sounding at the start of the bar's last `span` steps, struck every `span` steps.
            let head = loop.filter { $0.step <= spb - span }.map(\.step).max() ?? loop.map(\.step).min() ?? 0
            if heldSteps % span == 0 {
                for note in loop where note.step == head {
                    var n = note
                    n.params.lengthSteps = max(1, span / 2)
                    if Self.isHook(n) { n.params.pitch = n.params.pitch.map { transpose($0, by: rise, c, scale) } }
                    n.velocity = min(1, n.velocity * heard)
                    add(n)
                    if thirtySeconds {
                        var second = n
                        second.velocity *= 0.8
                        add(second, at: 0.5)
                    }
                }
            }
        }

        // The roll: the song's own snare (or hat, when it has no snare) at its tempo, harder as the charge fills.
        let songDrums = material.current.drums + material.drop.drums
        let hasSnare = songDrums.contains { $0.instrument == .snare }
        let rollInstrument: Instrument = hasSnare || songDrums.isEmpty ? .snare : .hat
        let rollEvery = charge < 0.2 ? 0 : (charge < 0.35 ? 4 : (charge < 0.5 ? 2 : 1))
        if rollEvery > 0, heldSteps % rollEvery == 0 {
            let velocity = 0.3 + 0.65 * charge
            add(make(rollInstrument, velocity * (bias.gain < 1 ? 0.7 : 1), NoteParams(pan: 0)))
            if thirtySeconds, bias.hatRoll { add(make(.hat, velocity * 0.6, NoteParams(pan: 0.2)), at: 0.5) }
        }
        return out
    }

    private static func isHook(_ note: ScheduledNote) -> Bool { DropGroove.hookInstruments.contains(note.instrument) }

    // MARK: Filter

    /// Where the master high-pass sits `heldSteps` after the press: it rises from open to a ceiling as the charge fills
    /// (slowly at first, faster at the end) and holds there until the release, when the caller sets
    /// `MasterFilter.idle` to snap it open. Gentle genres sweep to a lower ceiling and the band genres stay clear of
    /// the vocal range. Apply it each UI frame with `DropEngine.setMasterFilter`; it is a pure function of the hold.
    public static func filterSweep(heldSteps: Int, secondsPerStep: Double, genre: Genre) -> MasterFilter {
        guard heldSteps > 0 else { return .idle }
        let charge = charge(heldSteps: heldSteps, secondsPerStep: secondsPerStep)
        let ceiling: Float =
            switch style(of: genre) {
            case .gentle: 700
            case .band: 1_800
            default: 2_800
            }
        let position = Float(pow(charge, 1.4))
        let hz = MasterFilter.highPassOpen * powf(ceiling / MasterFilter.highPassOpen, position)
        return MasterFilter(highPassHz: hz, resonance: 0.15 + 0.3 * Float(charge))
    }

    // MARK: Drop

    /// The notes of the drop at `step`, `position` steps after it landed (0 is the downbeat). `power` is 0.8 ... 1 (it
    /// grows with the hold) and `charge` the build's final charge: the impact and the extra layers scale with it.
    public static func drop(position: Int, step: Int, power: Double, charge: Double, context c: DropContext)
        -> [ScheduledNote]
    {
        let material = c.material ?? DropMaterial.plain(keyRoot: c.keyRoot, stepsPerBar: c.stepsPerBar)
        let groove = material.drop
        let spb = material.stepsPerBar
        let half = spb / 2
        let pos = position % spb
        let bar = position / spb
        let bias = bias(c.genre)
        let scale = scale(c)
        let v = variant(c)
        let punch = 0.75 + 0.25 * min(1, max(0, charge))
        let gain = power * bias.gain
        var out: [ScheduledNote] = []
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) {
            out.append(
                ScheduledNote(step: step, instrument: instrument, velocity: min(1, velocity * gain), params: params))
        }
        // The song's notes that sound here. Half-time plays the bar at half speed across two bars.
        func sounding(_ notes: [ScheduledNote]) -> [ScheduledNote] {
            guard bias.stretch == 2 else { return notes.filter { $0.step == pos } }
            let window = (bar % 2) * half
            return notes.filter { $0.step >= window && $0.step < window + half && 2 * ($0.step - window) == pos }
                .map {
                    var n = $0
                    n.params.lengthSteps *= 2
                    return n
                }
        }

        // Drums: the song's own kit, with the impact on the downbeat of the first bar.
        var kickSounds = false
        for note in sounding(groove.drums) {
            if note.instrument == .kick { kickSounds = true }
            add(note.instrument, note.velocity, note.params)
        }
        if bias.fourOnFloor, pos % 4 == 0, !kickSounds { add(.kick, 1) }
        if bias.gatedSnare, pos == spb / 4 || pos == spb * 3 / 4 { add(.hat, 0.5) }
        if bar == 0, pos == 0 {
            if bias.impact > 0 { add(.impact, punch * bias.impact) }
            if bias.crash { add(.openHat, 1) }
            if bias.tapeStop, v == 0 { add(.tapeStop, 0.5) }
        }
        if pos >= spb - 4, bar % 2 == 1 {
            let t = Double(pos - (spb - 4)) / 3
            if bias.breakRoll { add(.snare, 0.4 + 0.5 * t) }
            if bias.hatRoll { add(.hat, 0.3 + 0.4 * t, NoteParams(pan: pos % 2 == 0 ? 0.25 : -0.25)) }
        }

        // Bass: the song's bass at full energy: driven harder, with a sub an octave under it.
        for note in sounding(groove.bass) {
            var n = note.params
            if n.voice == nil { n.voice = c.bassVoice }
            if note.instrument == .wobble { n.drive = min(1, (n.drive ?? 0.5) + bias.drive) }
            add(note.instrument, 1.0 * max(note.velocity, 0.7), n)
            if bias.layerSub, note.instrument != .sub, let pitch = n.pitch {
                add(.sub, 0.8, NoteParams(pitch: pitch - 12, lengthSteps: note.params.lengthSteps))
            }
        }

        // The hook: up an octave, harmonised a third above, or doubled up an octave and a fifth, always in the key.
        for note in sounding(groove.hook) {
            guard let pitch = note.params.pitch else { continue }
            var n = note.params
            switch v {
            case 0: n.pitch = pitch + 12
            case 1:
                add(note.instrument, note.velocity, note.params)
                n.pitch = transpose(pitch, by: 2, c, scale)
            default:
                n.pitch = pitch + 12
                var fifth = n
                fifth.pitch = transpose(pitch + 12, by: 4, c, scale)
                add(note.instrument, note.velocity * 0.7, fifth)
            }
            add(note.instrument, note.velocity, n)
        }

        // The chord lands with the downbeat; the next bar moves to the next chord.
        if pos == 0 {
            let root = bar % 2 == 1 ? (c.nextChordRoot ?? c.chordRoot) : c.keyRoot
            for tone in chord(root, scale: scale, c) {
                add(.keys, 0.5, NoteParams(pitch: fold(tone, 60...76), lengthSteps: spb, voice: 3))
            }
        }
        if bias.arpeggio, pos % 2 == 1 {
            let root = bar % 2 == 1 ? (c.nextChordRoot ?? c.chordRoot) : c.keyRoot
            let tones = chord(root, scale: scale, c)
            let index = (pos / 2) % (tones.count * 2 - 2)
            let tone = index < tones.count ? tones[index] : tones[tones.count * 2 - 2 - index]
            add(.keys, 0.5, NoteParams(pitch: fold(tone, 60...84), lengthSteps: 2, voice: 1))
        }
        return out
    }

    // MARK: Style

    enum Style { case gentle, band, other }

    static func style(of genre: Genre) -> Style {
        switch genre {
        case .chill, .lofi: .gentle
        case .rock, .folk, .funk: .band
        default: .other
        }
    }

    // MARK: Key

    /// The song's scale as pitch classes above the tonic: the classes its own bass and hook use (so a dorian or
    /// phrygian song keeps its altered degree), or natural minor or major plus what it plays when it gives too few notes.
    static func scale(_ c: DropContext) -> [Int] {
        var classes: Set<Int> = [0]
        if let material = c.material {
            for note in material.current.all + material.drop.all {
                if let pitch = note.params.pitch {
                    classes.insert(((pitch - c.keyRoot) % 12 + 12) % 12)
                }
            }
        }
        if classes.count >= 5, classes.count <= 8 { return classes.sorted() }
        return classes.union(c.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).sorted()
    }

    /// `pitch` moved `degrees` steps along the scale (an out-of-scale pitch first snaps down to the scale).
    static func transpose(_ pitch: Int, by degrees: Int, _ c: DropContext, _ scale: [Int]) -> Int {
        let rel = pitch - c.keyRoot
        let octave = Int((Double(rel) / 12).rounded(.down))
        let pc = rel - 12 * octave
        let index = scale.lastIndex { $0 <= pc } ?? 0
        let target = index + degrees
        let n = scale.count
        let wrapped = ((target % n) + n) % n
        let carried = Int((Double(target) / Double(n)).rounded(.down))
        return c.keyRoot + 12 * (octave + carried) + scale[wrapped]
    }

    /// The chord on `root`: its root, a third that stays in the scale and its fifth.
    static func chord(_ root: Int, scale: [Int], _ c: DropContext) -> [Int] {
        let offset = ((root - c.keyRoot) % 12 + 12) % 12
        let third = scale.contains((offset + 3) % 12) ? 3 : 4
        let fifth = scale.contains((offset + 7) % 12) ? 7 : (scale.contains((offset + 6) % 12) ? 6 : 12)
        return [root, root + third, root + fifth]
    }

    static func fold(_ pitch: Int, _ range: ClosedRange<Int>) -> Int {
        var p = pitch
        while p < range.lowerBound { p += 12 }
        while p > range.upperBound { p -= 12 }
        return p
    }
}
