import Foundation

// Per-genre arrangements for the DropConductor (#45). Everything here is a pure function of a StepContext: no state,
// no randomness, so the conductor can switch genre or track at a bar line without carrying anything over. A genre is
// more than a tempo: each has its own drums, its own bass instrument and its own way of carrying the track's hook:
//   dubstep  half-time; the hook is a big formant wobble riff, doubled by a bell in DROP2
//   riddim   sparse half-time; the same grimy triplet wobble riff, near one pitch, over and over
//   DnB      174 two-step breakbeat with ghost snares; the hook is a gliding reese line under electric-piano chords
//   trap     sparse kick, rolling hats, 808 slides; the hook is a bell melody over the 808
//   house    four-on-the-floor, off-beat bass, open hats; the hook is a swung rhythm of chord stabs
//   chill    soft swung drums, mellow pads; the hook is an electric-piano melody over a soft bass
// The vocabulary is the existing Instrument + NoteParams (plus .keys), so the audio engine needs no genre knowledge.

// MARK: - Public vocabulary

extension Genre {
    /// The tempo a genre is arranged for; switching genre moves the song to this BPM.
    public var defaultBPM: Double {
        switch self {
        case .dubstep, .riddim, .trap: 140
        case .drumAndBass: 174
        case .house: 124
        case .chill: 88
        }
    }

    /// A short label for the UI ("switching to DnB at the next bar").
    public var shortName: String {
        switch self {
        case .dubstep: "Dubstep"
        case .riddim: "Riddim"
        case .drumAndBass: "DnB"
        case .trap: "Trap"
        case .house: "House"
        case .chill: "Chill"
        }
    }
}

extension SongSettings {
    /// Settings for a genre at its own default tempo.
    public init(genre: Genre) {
        self.init()
        self.genre = genre
        self.bpm = genre.defaultBPM
    }
}

/// A tempo change the conductor applied: from `step` on (a bar boundary) the song is `genre` at `bpm`. A genre switch
/// moves to the genre's default tempo; a new track in the DJ set may nudge the tempo inside the genre's range.
/// The audio clock re-anchors at `step` with the new tempo; steps before it keep the old one.
public struct GenreSwitch: Sendable, Hashable, Codable {
    public var genre: Genre
    public var step: Int
    public var bpm: Double

    public init(genre: Genre, step: Int, bpm: Double) {
        self.genre = genre
        self.step = step
        self.bpm = bpm
    }
}

// MARK: - Context and profile

/// Where in the song a step sits, and what the arrangement may depend on.
struct StepContext {
    var step: Int
    var bar: Int
    var barStep: Int
    var perBar: Int
    var barInPhrase: Int
    var barsPerPhrase: Int
    var section: SongSection
    var level: Double
    var inboundShare: Double
    var track: Track
    var plan: PhrasePlan
    /// The section's wobble rate and bass patch: they change only where the section does.
    var wobbleRate: WobbleRate
    var voice: Int
    var dropComing: Bool
    /// Set through the last bar of a track that is handing over.
    var outro: Outro?
    /// The intro states the hook once the track has idled a phrase.
    var introHook: Bool

    /// Position on a 16-step bar grid, or nil when this step is between grid positions (odd bar sizes).
    var pos: Int? { (barStep * 16) % perBar == 0 ? barStep * 16 / perBar : nil }
    /// Position on the hook's two-bar grid.
    var hookPos: Int? { pos.map { (barInPhrase % 2) * 16 + $0 } }
    /// The bar's chord root, as a scale degree.
    var chord: Int { track.chord(barInPhrase) }
    var hook: Hook { track.hook(plan.variant(barInPhrase: barInPhrase)) }
    var keyRoot: Int { track.keyRoot }
    var outShare: Double { 1 - inboundShare }
    var isLastBar: Bool { barInPhrase == barsPerPhrase - 1 }
    var isHalfPhraseBar: Bool { barsPerPhrase >= 4 && barInPhrase == barsPerPhrase / 2 - 1 }
    /// The swing delay for a note at a 16-step position: only the off-16ths move.
    func swing(_ pos: Int) -> Double? { pos % 2 == 1 && track.swing > 0 ? track.swing : nil }

    /// A length written for a 16-step bar, scaled to this bar size.
    func scaled(_ steps: Int) -> Int { max(1, steps * perBar / 16) }
    /// The hook notes starting here.
    func hookNotes() -> [HookNote] { hookPos.map { hook.notes(at: $0) } ?? [] }
}

struct GenreProfile {
    var gain = 1.0
    var introKicks = [0]
    var introKickBarStride = 2
    var buildKicks = [0]
    var buildSnares = [8]
    var riserVelocity = 0.9
    /// Soft vox chops woven through every section.
    var chops = false
    /// The range the wobble formant stays inside, whatever the hook does to it.
    var formantRange: ClosedRange<Double> = 0...1
    /// Glide amount for legato bass (0 = the engine's short default).
    var glide: Double?
}

enum GenreArrangement {
    static func profile(_ genre: Genre) -> GenreProfile {
        switch genre {
        case .dubstep:
            GenreProfile(glide: 0.15)
        case .riddim:
            GenreProfile(formantRange: 0.1...0.6)
        case .drumAndBass:
            GenreProfile(buildKicks: [0, 10], buildSnares: [4, 12], formantRange: 0.05...0.35, glide: 0.35)
        case .trap:
            GenreProfile(glide: 0.5)
        case .house:
            GenreProfile(
                introKicks: [0, 4, 8, 12], introKickBarStride: 1, buildKicks: [0, 4, 8, 12], buildSnares: [4, 12],
                formantRange: 0.3...0.75)
        case .chill:
            GenreProfile(
                gain: 0.7, introKickBarStride: 4, buildSnares: [8], riserVelocity: 0.4, chops: true,
                formantRange: 0.2...0.6, glide: 0.4)
        }
    }

    // MARK: Pitch helpers

    /// Folds a sub pitch by octaves into the register the sub voice plays (MIDI 24 ... 40), staying in key.
    static func subRegister(_ pitch: Int) -> Int {
        var p = pitch
        while p > 40 { p -= 12 }
        while p < 24 { p += 12 }
        return p
    }

    /// A triad (or seventh) on a scale degree, as MIDI pitches from `base`.
    static func chord(_ c: StepContext, degree: Int, base: Int, seventh: Bool = false) -> [Int] {
        (seventh ? [0, 2, 4, 6] : [0, 2, 4]).map { c.track.pitch(base, degree: degree + $0) }
    }

    // MARK: Sections before the drop

    /// Intro, build and breakdown: a light bed that already sounds like the genre and the track. The build states the
    /// hook on keys so the drop's riff is already familiar when it lands.
    static func bed(_ genre: Genre, _ c: StepContext) -> [ScheduledNote] {
        guard let pos = c.pos else { return [] }
        let p = profile(genre)
        var out: [ScheduledNote] = []
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) {
            var params = params
            if params.delay == nil { params.delay = c.swing(pos) }
            out.append(
                ScheduledNote(
                    step: c.step, instrument: instrument, velocity: min(1, max(0, velocity * p.gain)), params: params))
        }
        let variant = c.track.drums
        let subPitch = c.track.pitch(c.keyRoot - 36, degree: c.chord)
        switch c.section {
        case .intro:
            if p.introKicks.contains(pos), c.bar % p.introKickBarStride == 0 { add(.kick, 0.55) }
            let hats: [[Int]] = [[2, 6, 10, 14], [2, 6, 10, 13, 14], [2, 5, 10, 14], [2, 6, 11, 14]]
            if c.level > 0.08, hats[variant % hats.count].contains(pos) {
                add(.hat, (pos % 4 == 2 ? 0.18 : 0.12) + 0.3 * c.level)
            }
            // Once the input wakes up, a soft sub hums the progression two bars at a time.
            if c.level > 0.3, pos == 0, c.barInPhrase % 2 == 0 {
                add(.sub, 0.4, NoteParams(pitch: subPitch, lengthSteps: c.perBar * 2))
            }
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.22, add: add) }
            if c.introHook { keysHook(genre, c, velocity: 0.3, add: add) }
        case .breakdown:
            if pos == 0, c.barInPhrase % 4 == 0 { add(.kick, 0.45) }
            if c.level > 0.08, pos % 4 == 2 { add(.hat, 0.15 + 0.2 * c.level) }
            if pos == 0 { add(.sub, 0.45, NoteParams(pitch: subPitch, lengthSteps: c.perBar)) }
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.3, add: add) }
        case .build:
            if p.buildKicks.contains(pos) { add(.kick, pos == 0 ? 0.9 : 0.75) }
            let rush = c.barInPhrase >= 6 && c.level > 0.7
            if pos % 2 == 0 || rush { add(.hat, (pos % 2 == 0 ? 0.3 : 0.18) + 0.3 * c.level) }
            // The snare tightens across the phrase: the genre's backbeat, then every beat, then 8ths.
            if !c.dropComing {
                let ramp = 0.45 + 0.4 * Double(c.barInPhrase) / Double(max(1, c.barsPerPhrase - 1))
                let fraction = Double(c.barInPhrase) / Double(max(1, c.barsPerPhrase))
                if fraction < 0.5 {
                    if p.buildSnares.contains(pos) { add(.snare, 0.8) }
                } else if fraction < 0.75 {
                    if pos % 4 == 0 { add(.snare, ramp) }
                } else if pos % 2 == 0 {
                    add(.snare, ramp)
                }
            }
            if pos == 0 { add(.sub, 0.55, NoteParams(pitch: subPitch, lengthSteps: c.perBar)) }
            // The hook, stated on keys and growing toward the drop.
            let grow = 0.35 + 0.3 * Double(c.barInPhrase) / Double(max(1, c.barsPerPhrase - 1))
            keysHook(genre, c, velocity: grow, add: add)
        case .drop, .drop2:
            break
        }
        return out
    }

    /// Soft pad chords (keys voice 3) on the bar's chord, two bars long.
    private static func pad(_ c: StepContext, velocity: Double, add: (Instrument, Double, NoteParams) -> Void) {
        for pitch in chord(c, degree: c.chord, base: c.keyRoot - 12, seventh: c.track.genre == .chill) {
            add(.keys, velocity, NoteParams(pitch: pitch, lengthSteps: c.perBar * 2, voice: 3))
        }
    }

    /// The hook on the track's keys: single notes, or chord stabs for house.
    private static func keysHook(
        _ genre: Genre, _ c: StepContext, velocity: Double,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        for note in c.hookNotes() {
            let accent = note.accent ? 1.0 : 0.82
            let degree = c.chord + note.degree
            if genre == .house {
                for pitch in chord(c, degree: degree, base: c.keyRoot) {
                    add(
                        .keys, velocity * accent, NoteParams(pitch: pitch, lengthSteps: c.scaled(note.length), voice: 1)
                    )
                }
            } else {
                let base = genre == .chill || genre == .drumAndBass ? c.keyRoot : c.keyRoot + 12
                add(
                    .keys, velocity * accent,
                    NoteParams(
                        pitch: c.track.pitch(base, degree: degree), lengthSteps: c.scaled(note.length),
                        voice: c.track.keysVoice))
            }
        }
    }

    /// The breakdown's vocal lead: the hook's long notes on vox, an octave down from the keys.
    static func lead(_ c: StepContext) -> [ScheduledNote] {
        guard c.section == .breakdown else { return [] }
        return c.hookNotes().filter { $0.length >= 3 }.map { note in
            let pitch = c.track.pitch(c.keyRoot - 12, degree: c.chord + note.degree)
            return ScheduledNote(
                step: c.step, instrument: .vox, velocity: 0.42,
                params: NoteParams(pitch: pitch, lengthSteps: c.scaled(note.length), voice: c.track.vowel))
        }
    }

    // MARK: The drop

    /// Drums, bass and keys for one step of a drop section.
    static func drop(_ genre: Genre, _ c: StepContext) -> [ScheduledNote] {
        guard let pos = c.pos else { return [] }
        var out: [ScheduledNote] = []
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams) {
            var params = params
            if params.delay == nil { params.delay = c.swing(pos) }
            out.append(
                ScheduledNote(step: c.step, instrument: instrument, velocity: min(1, max(0, velocity)), params: params))
        }
        let fill = activeFill(c, pos: pos)
        drums(genre, c, pos: pos, fill: fill, add: add)
        bass(genre, c, pos: pos, fill: fill, add: add)
        keys(genre, c, pos: pos, fill: fill, add: add)
        return out
    }

    /// The fill acting at this position, with where its zone starts (the last bar's, or the half-phrase's last beat).
    static func activeFill(_ c: StepContext, pos: Int) -> (kind: Fill, from: Int)? {
        if c.isLastBar {
            let from: Int
            switch c.plan.fill {
            case .halfTime: from = 0
            case .bassStutter: from = 8
            case .tripletRoll: from = 10
            case .snareRoll, .kickDrop: from = 12
            }
            return (c.plan.fill, from)
        }
        if c.isHalfPhraseBar, let mid = c.plan.midFill { return (mid, 14) }
        return nil
    }

    private static func drums(
        _ genre: Genre, _ c: StepContext, pos: Int, fill: (kind: Fill, from: Int)?,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        let bank = Banks.drums(genre)
        let variant = bank[(c.section == .drop2 ? c.track.drums2 : c.track.drums) % bank.count]
        let level = c.level
        let soft = genre == .chill
        let inFill = fill.map { pos >= $0.from } ?? false
        let kind = inFill ? fill?.kind : nil
        let main = c.isLastBar  // the half-phrase fill only whispers

        var kicks = c.barInPhrase % 2 == 0 ? variant.kicksA : variant.kicksB
        var snares = variant.snares
        if kind == .halfTime {
            if snares.contains(4) {
                kicks = [0, 10]
                snares = [8]
            } else {
                kicks = [0, 6, 10]
                snares = [4, 8, 12]
            }
        }
        if kind == .kickDrop { kicks = [] }
        if kicks.contains(pos) {
            let velocity = pos == 0 ? (soft ? 0.7 : 1.0) : (soft ? 0.4 : genre == .house ? 0.95 : 0.75)
            add(.kick, velocity, NoteParams())
        }

        let snareVelocity = soft ? 0.5 : genre == .house ? 0.75 : 1.0
        var snared = false
        if snares.contains(pos) {
            add(.snare, snareVelocity, NoteParams())
            snared = true
        } else if let kind, kind == .snareRoll || kind == .tripletRoll {
            let hits = kind == .snareRoll ? [12, 13, 14, 15] : [11, 13, 15]
            if hits.contains(pos) {
                let rise = Double(pos - (fill?.from ?? 12)) / 4
                add(.snare, main ? (0.5 + 0.35 * rise) * snareVelocity : 0.25 + 0.15 * rise, NoteParams())
                snared = true
            }
        }
        let ghostChance = c.track.ghostDensity * (genre == .drumAndBass ? 1 : 0.4 + 0.6 * level)
        if !snared, variant.ghosts.contains(pos), c.plan.unit(c.bar, UInt64(pos) &+ 101) < ghostChance {
            add(.snare, 0.16 + 0.14 * c.plan.unit(c.bar, UInt64(pos) &+ 211), NoteParams())
        }

        // Hats: each genre its own pattern; energy only thickens it.
        let accent = pos % 4 == 0 ? 0.1 : 0
        switch genre {
        case .trap:
            // Programmed rolls every other bar end: 16ths speeding into the next bar, the trap signature.
            if c.barInPhrase % 2 == 1, pos >= 12 {
                add(.hat, 0.4 + 0.15 * Double(pos - 12), NoteParams())
            } else if c.barInPhrase % 4 == 2, pos >= 13 {
                add(.hat, 0.35 + 0.1 * Double(pos - 13), NoteParams())
            } else if pos % 2 == 0 || (level > 0.85 && pos % 4 == 3) {
                add(.hat, (pos % 2 == 0 ? 0.3 : 0.2) + 0.3 * level, NoteParams())
            }
        case .house:
            if pos == 2 || pos == 10 { add(.hat, 0.35 + 0.2 * level, NoteParams()) }
            if level > 0.6, pos % 2 == 1 { add(.hat, 0.12 + 0.1 * level, NoteParams()) }
        case .riddim:
            if level > 0.4, pos == 4 || pos == 12 { add(.hat, 0.25 + 0.3 * level, NoteParams()) }
            if level > 0.8, pos % 4 == 2 { add(.hat, 0.2 + 0.2 * level, NoteParams()) }
        case .chill:
            // Soft swung 16ths: the off-16ths lean late (the swing) and quiet.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.22 : 0.12) + 0.12 * level, NoteParams()) }
            if pos % 4 == 3 { add(.hat, 0.1 + 0.08 * level, NoteParams()) }
        case .drumAndBass:
            // Breakbeat hats: 8ths with a swung 16th before the snare.
            if pos % 2 == 0 { add(.hat, 0.32 + 0.3 * level + accent, NoteParams()) }
            if pos == 3 || pos == 11 || (level > 0.8 && pos % 2 == 1) { add(.hat, 0.2 + 0.15 * level, NoteParams()) }
        case .dubstep:
            let stride = level < 0.5 ? 4 : level < 0.75 ? 2 : 1
            if pos % stride == (stride == 4 ? 2 : 0) {
                add(.hat, (stride == 1 && pos % 2 == 1 ? 0.25 : 0.35) + 0.3 * level + accent, NoteParams())
            }
        }
        if variant.openHats.contains(pos), genre == .house || level > 0.6, kind != .kickDrop {
            add(.openHat, 0.55 + 0.25 * level, NoteParams())
        }
    }

    private static func bass(
        _ genre: Genre, _ c: StepContext, pos: Int, fill: (kind: Fill, from: Int)?,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        if c.outro == .drumBridge { return }
        let p = profile(genre)
        let track = c.track
        let wobbleBase = c.keyRoot - 24
        let pan = (c.outShare - c.inboundShare) * 0.5
        let cut = fill.flatMap { $0.kind == .kickDrop ? $0.from : nil }
        let stutterFrom = fill.flatMap { $0.kind == .bassStutter ? $0.from : nil }
        // The filter sweep outro closes the bass and fades it through the last bar.
        let sweep = c.outro == .filterSweep ? 1 - Double(c.barStep) / Double(c.perBar) : 1

        /// A note's length, cut short where a kick drop silences the bass.
        func length(_ steps: Int) -> Int {
            guard let cut, pos < cut else { return c.scaled(steps) }
            return c.scaled(min(steps, cut - pos))
        }
        if let cut, pos >= cut { return }

        func wobble(_ pitch: Int, _ steps: Int, velocity: Double, accent: Bool) {
            let formant =
                min(p.formantRange.upperBound, max(p.formantRange.lowerBound, track.formant + (accent ? 0.2 : 0)))
                * sweep
            let note = NoteParams(
                pitch: pitch, lengthSteps: length(steps), wobbleRate: c.wobbleRate, formant: formant,
                drive: track.drive, voice: c.voice, pan: pan, glide: p.glide)
            add(.wobble, velocity * (0.3 + 0.7 * sweep), note)
        }

        // The stutter fill: octave-jumping 16th stabs on the chord root.
        if let stutterFrom, pos >= stutterFrom {
            let pitch = track.pitch(wobbleBase, degree: c.chord) + (pos % 2 == 1 ? 12 : 0)
            if genre == .trap {
                add(
                    .sub, 0.9,
                    NoteParams(
                        pitch: subRegister(track.pitch(c.keyRoot - 36, degree: c.chord + (pos % 4 == 2 ? 4 : 0))),
                        lengthSteps: c.scaled(1)))
            } else {
                wobble(pitch, 1, velocity: 0.85 + (pos % 2 == 0 ? 0.1 : 0), accent: pos % 4 == 0)
            }
            return
        }

        let subPitch = track.pitch(c.keyRoot - 36, degree: c.chord)
        switch genre {
        case .dubstep, .drumAndBass:
            if pos == 0 { add(.sub, 0.9, NoteParams(pitch: subPitch, lengthSteps: length(16))) }
        case .chill:
            if pos == 0 { add(.sub, 0.7, NoteParams(pitch: subPitch, lengthSteps: length(16))) }
        case .riddim:
            if pos == 0 || pos == 8 {
                add(.sub, pos == 0 ? 1.0 : 0.95, NoteParams(pitch: subPitch, lengthSteps: length(8), drive: 0.9))
            }
        case .house:
            // Off-beat bass: sub and a short wub in every gap between the kicks.
            if pos % 4 == 2 {
                let octave = pos == 6 || pos == 14 ? 12 : 0
                add(.sub, 0.85, NoteParams(pitch: subPitch, lengthSteps: length(2)))
                wobble(track.pitch(wobbleBase, degree: c.chord) + octave, 2, velocity: 0.7, accent: pos == 2)
            }
        case .trap:
            break
        }

        let hook = c.hookNotes()
        switch genre {
        case .dubstep, .riddim, .drumAndBass:
            // The hook itself, on the wobble: the riff that repeats through every drop of the track.
            for note in hook {
                let velocity = note.accent ? 1.0 : 0.85
                wobble(
                    track.pitch(wobbleBase, degree: c.chord + note.degree), note.length, velocity: velocity,
                    accent: note.accent)
            }
        case .trap:
            // 808 slides on the hook's rhythm: root, fifth and octave, gliding from note to note.
            let notes = c.hook.notes
            for note in hook {
                let index = notes.firstIndex(of: note) ?? 0
                let next = index + 1 < notes.count ? notes[index + 1].pos : 32
                let barEnd = note.pos < 16 ? 16 : 32
                let span = max(1, min(next, barEnd) - note.pos)
                let degree = note.degree >= 6 ? 7 : note.degree >= 3 ? 4 : 0
                let pitch = subRegister(track.pitch(c.keyRoot - 36, degree: c.chord + degree))
                add(.sub, note.accent ? 1.0 : 0.9, NoteParams(pitch: pitch, lengthSteps: length(span), glide: p.glide))
            }
        case .chill:
            // A soft bass that breathes with the chords, not the hook.
            if pos == 0 || pos == 8 {
                wobble(
                    track.pitch(wobbleBase, degree: c.chord + (pos == 8 && c.barInPhrase % 2 == 1 ? 4 : 0)), 8,
                    velocity: 0.5, accent: false)
            }
        case .house:
            break
        }
    }

    /// The keys layer of a drop: where trap, house and chill carry their hook, and where DnB and DROP2 add harmony.
    private static func keys(
        _ genre: Genre, _ c: StepContext, pos: Int, fill: (kind: Fill, from: Int)?,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        if c.outro == .drumBridge { return }
        switch genre {
        case .trap:
            keysHook(genre, c, velocity: 0.62, add: add)
        case .house:
            keysHook(genre, c, velocity: 0.58, add: add)
        case .chill:
            keysHook(genre, c, velocity: 0.5, add: add)
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.26, add: add) }
        case .drumAndBass:
            if pos == 0, c.barInPhrase % 2 == 0 {
                for pitch in chord(c, degree: c.chord, base: c.keyRoot, seventh: true) {
                    add(.keys, 0.28, NoteParams(pitch: pitch, lengthSteps: c.scaled(28), voice: 2))
                }
            }
        case .dubstep:
            // DROP2's big moment: a bell doubles the riff two octaves up.
            if c.section == .drop2 { keysHook(genre, c, velocity: 0.34, add: add) }
        case .riddim:
            break
        }
    }

    /// The hat roll a burst of ticks triggers on trap, as (steps after the burst, velocity). On a 16th-note grid a
    /// 1/32 roll is a run of consecutive 16ths and a triplet burst is the nearest 16ths to an even six-in-eight.
    static func hatRoll(bar: Int, step: Int) -> [(offset: Int, velocity: Double)] {
        if (bar + step / 4) % 2 == 0 {
            return [(1, 0.5), (2, 0.6), (3, 0.7), (4, 0.85)]
        }
        return [(1, 0.5), (3, 0.6), (4, 0.7), (5, 0.8), (7, 0.9)]
    }
}
