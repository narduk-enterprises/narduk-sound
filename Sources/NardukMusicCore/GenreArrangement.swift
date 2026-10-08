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
//   rock     a live kit, driven power-chord 8ths on electric strums over a picking bass guitar (narduk-libs#1578)
//   folk     soft kit, the folk strum on an acoustic, a root-fifth bass and a fingerpicked acoustic hook
//   funk     syncopated kit with ghost snares, muted 16th chicken scratch and a popping 16th bass line
//   tropical a soft, round four-on-the-floor with a recorded off-beat shaker; the hook is a recorded steel drum or flute
//   pluck over piano chords and pumping pads
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
        case .techno, .ukGarage: 132
        case .synthwave: 108
        case .lofi: 80
        case .rock: 124
        case .folk: 96
        case .funk: 104
        case .tropicalHouse: 106
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
        case .techno: "Techno"
        case .ukGarage: "UK Garage"
        case .synthwave: "Synthwave"
        case .lofi: "Lo-fi"
        case .rock: "Rock"
        case .folk: "Folk"
        case .funk: "Funk"
        case .tropicalHouse: "Tropical House"
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
    /// The phrase of the section this step is in (0 for its first), and how many phrases the section is planned to
    /// last (a build's length; 1 for the others, whose length is open).
    var phraseInSection = 0
    var sectionPhrases = 1
    /// How the chords are voiced, and the chord layer played over the arrangement; nil is the arrangement's own.
    var voicing: ChordVoicing?
    var comping: CompingPattern?
    /// How much each part is written (`PartEmphasis`); neutral writes the genre as it is.
    var emphasis = PartEmphasis.neutral

    /// A stable 0 ..< 1 draw for this bar and a purpose, so an emphasis choice holds for the whole bar.
    func draw(_ salt: UInt64) -> Double { plan.unit(bar, salt) }
    /// Whether a part pushed above 1 takes an extra choice in this bar (never at neutral).
    func adds(_ part: PartEmphasis.Part, _ salt: UInt64) -> Bool { emphasis.adds(part, draw(salt)) }

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

    /// How far through its build this bar is: 0 on the first bar, 1 on the last of the planned build.
    var buildProgress: Double {
        let total = max(1, sectionPhrases) * barsPerPhrase
        let bar = min(phraseInSection, max(1, sectionPhrases) - 1) * barsPerPhrase + barInPhrase
        return total > 1 ? min(1, Double(bar) / Double(total - 1)) : 1
    }
    /// The second half of the phrase.
    var inSecondHalf: Bool { barsPerPhrase >= 4 && barInPhrase >= barsPerPhrase / 2 }

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
    /// No whomps: no riser, impact or tape stop, no snare roll into the drop and no rushing build snare (tropical
    /// house). The drop is a lift, not a slam.
    var gentle = false
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
        case .techno:
            GenreProfile(
                introKicks: [0, 4, 8, 12], introKickBarStride: 1, buildKicks: [0, 4, 8, 12], buildSnares: [4, 12],
                formantRange: 0.15...0.5)
        case .ukGarage:
            GenreProfile(buildKicks: [0, 10], buildSnares: [4, 12], formantRange: 0.25...0.6, glide: 0.2)
        case .synthwave:
            GenreProfile(
                introKicks: [0, 8], introKickBarStride: 1, buildKicks: [0, 8], buildSnares: [4, 12],
                riserVelocity: 0.7, formantRange: 0.3...0.7, glide: 0.25)
        case .lofi:
            GenreProfile(
                gain: 0.65, introKickBarStride: 4, buildKicks: [0, 10], buildSnares: [4, 12], riserVelocity: 0.35,
                chops: true, formantRange: 0.15...0.5, glide: 0.3)
        case .rock:
            GenreProfile(
                introKicks: [0, 8], introKickBarStride: 1, buildKicks: [0, 8], buildSnares: [4, 12],
                riserVelocity: 0.55, formantRange: 0.3...0.7)
        case .folk:
            GenreProfile(
                gain: 0.75, introKickBarStride: 4, buildKicks: [0, 8], buildSnares: [12], riserVelocity: 0.3,
                formantRange: 0.3...0.6)
        case .funk:
            GenreProfile(
                introKicks: [0, 10], introKickBarStride: 1, buildKicks: [0, 10], buildSnares: [4, 12],
                riserVelocity: 0.5, formantRange: 0.3...0.7)
        case .tropicalHouse:
            GenreProfile(
                gain: 0.85, introKicks: [0, 4, 8, 12], introKickBarStride: 1, buildKicks: [0, 4, 8, 12],
                buildSnares: [4, 12], riserVelocity: 0, formantRange: 0.1...0.4, glide: 0, gentle: true)
        }
    }

    // MARK: Transitions

    /// How a genre arrives at a drop. Every genre used to land the same way (a riser, a snare roll and an impact),
    /// which made every drop and hand-over sound alike; each genre now has one of a few distinct forms.
    enum DropEntry: Sendable {
        /// A riser over the last bar, a snare roll speeding into the line and an impact on the one.
        case slam
        /// No riser and no impact: the build's kit opens up like a filter and the drop arrives on the kick alone.
        case filterOpen
        /// A quiet pickup: a soft riser, no roll but a soft snare run over the last beat, and a light impact.
        case pickup
        /// A drummer's fill: snare and kick trading 16ths over the last beat, then a crash instead of an impact.
        case bandFill
        /// Nothing: the music has no drops (ambient).
        case none
    }

    static func dropEntry(_ genre: Genre) -> DropEntry {
        switch genre {
        case .dubstep, .riddim, .trap, .drumAndBass: .slam
        case .house, .techno, .ukGarage: .filterOpen
        case .chill, .lofi, .synthwave: .pickup
        case .rock, .folk, .funk: .bandFill
        // Tropical house's drop is a lift: the groove opens back up after the build thins out, with no riser,
        // impact or stutter (its gentle profile keeps the conductor's transitions off as well).
        case .tropicalHouse: .filterOpen
        }
    }

    /// Which drop phrases end on a master cut, and whether a stutter cut leads into the drop, for a track whose
    /// vocal plan has cuts. A cut on every drop phrase of every genre was the same punctuation over and over.
    static func cutsOnDropPhrase(_ genre: Genre, phraseInSection: Int) -> Bool {
        switch genre {
        case .tropicalHouse: false  // a lift marks its changes by taking parts away, not by cutting the master
        case .dubstep, .riddim, .trap, .drumAndBass, .ukGarage: phraseInSection % 2 == 1
        case .house, .techno, .synthwave, .chill, .lofi: phraseInSection % 4 == 3
        case .rock, .folk, .funk: false
        }
    }

    static func stuttersIntoDrop(_ genre: Genre) -> Bool {
        switch dropEntry(genre) {
        case .slam: true
        case .filterOpen, .pickup, .bandFill, .none: false
        }
    }

    // MARK: Band guitars

    /// Rock, folk and funk: the guitars carry the chords and hook and a bass guitar replaces the sub.
    static func isBand(_ genre: Genre) -> Bool { genre.family == .band }

    /// The part that carries a genre's hook and pads: the guitar in a band, the keys everywhere else.
    static func hookPart(_ genre: Genre) -> PartEmphasis.Part { isBand(genre) ? .guitar : .keys }

    /// The chord (strum) and single-note (lead) guitar the genre plays.
    private static func guitars(_ genre: Genre) -> (strum: Instrument, lead: Instrument) {
        genre == .folk ? (.strum, .acousticGuitar) : (.electricStrum, .electricGuitar)
    }

    /// Folds a pitch by octaves into the bass guitar's range (E1 ... D#2, MIDI 28 ... 39), staying in key.
    static func bassRegister(_ pitch: Int) -> Int {
        var p = pitch
        while p > 39 { p -= 12 }
        while p < 28 { p += 12 }
        return p
    }

    /// The strum voice for a chord on a degree: 0 major, 1 minor, 2 dominant 7, 3 minor 7, 4 power, 5 sus2. Rock plays
    /// power chords, folk the triads, funk sevenths.
    static func strumVoice(_ genre: Genre, _ c: StepContext, degree: Int) -> Int {
        let mode = c.track.mode
        let minor = mode.semitones(degree + 2) - mode.semitones(degree) == 3
        switch genre {
        case .rock: return 4
        case .funk: return minor ? 3 : 2
        default: return minor ? 1 : 0
        }
    }

    /// One chord stroke of the genre's guitar on the bar's chord (or `degree`), strummed up when `up`.
    private static func strum(
        _ genre: Genre, _ c: StepContext, velocity: Double, length: Int, up: Bool = false, degree: Int? = nil,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        let degree = degree ?? c.chord
        add(
            guitars(genre).strum, velocity,
            NoteParams(
                pitch: c.track.pitch(c.keyRoot - 12, degree: degree), lengthSteps: c.scaled(length),
                formant: up ? 0.6 : 0.2, drive: c.track.drive, voice: strumVoice(genre, c, degree: degree)))
    }

    /// The hook on the genre's lead guitar, one octave above the keys' middle register.
    private static func guitarHook(
        _ genre: Genre, _ c: StepContext, velocity: Double, add: (Instrument, Double, NoteParams) -> Void
    ) {
        for note in c.hookNotes() {
            add(
                guitars(genre).lead, velocity * (note.accent ? 1.0 : 0.82),
                NoteParams(
                    pitch: c.track.pitch(c.keyRoot + 12, degree: c.chord + note.degree),
                    lengthSteps: c.scaled(note.length), drive: c.track.drive))
        }
    }

    /// The rhythm part of a drop: rock chugs power chords on the 8ths, folk plays the folk strum (and in the
    /// breakdown fingerpicks an arpeggio), funk scratches muted 16ths with the chord ringing on 1 and 3.
    private static func rhythmGuitar(
        _ genre: Genre, _ c: StepContext, pos: Int, add: (Instrument, Double, NoteParams) -> Void
    ) {
        let gain: Double = c.section == .drop2 ? 1 : 0.9
        switch genre {
        case .rock:
            guard pos % 2 == 0 else { return }
            // The downbeats ring, the back beat leans, the rest are palm-muted chugs.
            let ring = pos == 0 || pos == 8
            strum(
                genre, c, velocity: (ring ? 0.62 : pos % 4 == 0 ? 0.5 : 0.42) * gain, length: ring ? 4 : 1, add: add)
        case .folk:
            for hit in CompingPattern.folk.hits(pos: pos, barInPhrase: c.barInPhrase) {
                strum(
                    genre, c, velocity: 0.5 * hit.velocity * gain, length: hit.length, up: hit.direction == .up,
                    add: add)
            }
        case .funk:
            let table: [Double] = [
                0.55, 0, 0.3, 0.3, 0.45, 0, 0.62, 0.3, 0.5, 0, 0.3, 0.3, 0.45, 0.3, 0.62, 0,
            ]
            let velocity = table[pos]
            guard velocity > 0 else { return }
            // The stronger hits let the chord ring a moment; the soft ones are the muted scratch.
            strum(
                genre, c, velocity: velocity * gain, length: velocity >= 0.5 ? 2 : 1, up: pos % 2 == 1 || pos == 6,
                add: add)
        default:
            break
        }
    }

    /// The bass guitar line of a drop.
    private static func bandBass(
        _ genre: Genre, _ c: StepContext, pos: Int, length: (Int) -> Int,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        let base = c.keyRoot - 24
        func note(_ offset: Int, octave: Int = 0, velocity: Double, steps: Int, drive: Double? = nil) {
            let pitch = bassRegister(c.track.pitch(base, degree: c.chord + offset)) + octave
            add(.bassGuitar, velocity, NoteParams(pitch: pitch, lengthSteps: length(steps), drive: drive))
        }
        switch genre {
        case .rock:
            // Driving 8ths on the root; the last one of the bar leans to the fifth to turn the bar over.
            guard pos % 2 == 0 else { return }
            let turn = pos == 14 && c.barInPhrase % 2 == 1
            note(turn ? 4 : 0, velocity: pos % 4 == 0 ? 0.85 : 0.68, steps: 2, drive: 0.3)
        case .folk:
            // Root on the one, fifth on the three: the oom-pah underneath the strum.
            if pos == 0 { note(0, velocity: 0.8, steps: 8) }
            if pos == 8 { note(4, velocity: 0.62, steps: 8) }
        case .funk:
            // A syncopated 16th line: long root on the one, octave pops, the fifth and the flat seven as answers.
            switch pos {
            case 0: note(0, velocity: 0.95, steps: 3, drive: 0.15)
            case 3: note(0, octave: 12, velocity: 0.6, steps: 1, drive: 0.55)
            case 6: note(4, velocity: 0.7, steps: 2, drive: 0.15)
            case 8: note(0, velocity: 0.8, steps: 2, drive: 0.15)
            case 10: note(0, velocity: 0.7, steps: 1, drive: 0.15)
            case 11: note(0, octave: 12, velocity: 0.55, steps: 1, drive: 0.55)
            case 14: note(6, velocity: 0.65, steps: 1, drive: 0.15)
            default: break
            }
        default:
            break
        }
    }

    /// Genres whose chords carry sevenths.
    static func lush(_ genre: Genre) -> Bool { genre == .chill || genre == .lofi || genre == .ukGarage }

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
        guard let voicing = c.voicing else {
            return (seventh ? [0, 2, 4, 6] : [0, 2, 4]).map { c.track.pitch(base, degree: degree + $0) }
        }
        return Harmony.pitches(mode: c.track.mode, tonic: base, degree: degree, voicing: voicing, seventh: seventh)
    }

    /// The chord layer: the bar's chord, voiced, played in the pattern's strokes on electric piano keys (pad keys for
    /// held chords). Quieter in the intro and breakdown, full in the drops.
    static func comp(_ c: StepContext, pattern: CompingPattern) -> [ScheduledNote] {
        guard let pos = c.pos, c.outro != .drumBridge else { return [] }
        let gain: Double =
            switch c.section {
            case .intro: 0.5
            case .breakdown: 0.65
            case .build: 0.8
            case .drop, .drop2: 1
            }
        let chord = Self.chord(c, degree: c.chord, base: c.keyRoot, seventh: Self.lush(c.track.genre))
        let voice = pattern == .sustain ? 3 : 2
        return pattern.hits(pos: pos, barInPhrase: c.barInPhrase).flatMap { hit in
            hit.notes(on: chord).map { note in
                ScheduledNote(
                    step: c.step, instrument: .keys, velocity: min(1, max(0, 0.42 * gain * note.velocity)),
                    params: NoteParams(
                        pitch: note.pitch, lengthSteps: c.scaled(hit.length), voice: voice,
                        delay: note.delay > 0 ? note.delay : nil))
            }
        }
    }

    // MARK: Sections before the drop

    /// Intro, build and breakdown: a light bed that already sounds like the genre and the track. The build states the
    /// hook on keys so the drop's riff is already familiar when it lands.
    static func bed(_ genre: Genre, _ c: StepContext) -> [ScheduledNote] {
        guard let pos = c.pos else { return [] }
        let p = profile(genre)
        var out: [ScheduledNote] = []
        // Over a build's last quarter the hats and snares open up like a filter: their noise bands climb from the
        // kit's tuning to the top of the range, bar by bar into the drop.
        let opening = c.section == .build && !p.gentle ? max(0, (c.buildProgress - 0.75) / 0.25) : 0
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) {
            var params = params
            if params.delay == nil { params.delay = c.swing(pos) }
            if params.formant == nil, let tune = c.track.drumTune(instrument) {
                let opens = opening > 0 && (instrument == .hat || instrument == .snare)
                params.formant = opens ? tune + (1 - tune) * min(1, opening + Double(pos) / 64) : tune
            }
            out.append(
                ScheduledNote(
                    step: c.step, instrument: instrument, velocity: min(1, max(0, velocity * p.gain)), params: params))
        }
        let variant = c.track.drums
        let band = isBand(genre)
        let low: Instrument = band ? .bassGuitar : .sub
        let subPitch =
            band
            ? bassRegister(c.track.pitch(c.keyRoot - 24, degree: c.chord))
            : c.track.pitch(c.keyRoot - 36, degree: c.chord)
        // A gentle genre's held sub stops a step short, so it never glides into the next chord's root.
        func held(_ steps: Int) -> Int { p.gentle ? steps - 1 : steps }
        switch c.section {
        case .intro:
            let style = c.track.introStyle
            // Drums pushed up enter earlier: the kick on every bar from the start, the hats before the input wakes.
            let drumsIn = c.adds(.drums, 0x1D01)
            let kicks = (style != 1 && style != 3) || drumsIn
            let stride = drumsIn ? 1 : (style == 2 ? 1 : p.introKickBarStride)
            if kicks, p.introKicks.contains(pos), c.bar % stride == 0 {
                add(.kick, 0.55)
            }
            let hats: [[Int]] = [[2, 6, 10, 14], [2, 6, 10, 13, 14], [2, 5, 10, 14], [2, 6, 11, 14]]
            if style != 1 || drumsIn, c.level > (style == 2 || drumsIn ? 0 : 0.08),
                hats[variant % hats.count].contains(pos)
            {
                add(.hat, (pos % 4 == 2 ? 0.18 : 0.12) + 0.3 * max(c.level, style == 2 ? 0.3 : 0))
            }
            // Once the input wakes up, a soft sub hums the progression two bars at a time; bass pushed up hums from
            // the start, and every bar.
            let bassIn = c.adds(.bass, 0x1D02)
            if c.level > (style == 3 || bassIn ? 0 : 0.3), pos == 0, c.barInPhrase % 2 == 0 || bassIn {
                add(
                    low, style == 3 ? 0.55 : 0.4,
                    NoteParams(pitch: subPitch, lengthSteps: held(c.perBar * (bassIn ? 1 : 2))))
            }
            // The second half of every phrase moves: the pad swells and a soft hat pickup leads into the bars between.
            let swell = c.inSecondHalf ? 1.3 : 1
            if style != 2, pos == 0, c.barInPhrase % 2 == 0 {
                pad(c, velocity: (style == 1 ? 0.36 : 0.22) * swell, add: add)
            }
            if c.inSecondHalf, pos == 15, style == 2 || c.barInPhrase % 2 == 1 { add(.hat, 0.12 + 0.2 * c.level) }
            // The hook part pushed up states the hook from the track's first phrase.
            if c.introHook || c.adds(hookPart(genre), 0x1D03) { keysHook(genre, c, velocity: 0.3, add: add) }
            introLayers(genre, c, pos: pos, subPitch: subPitch, add: add)
        case .breakdown:
            let style = c.track.breakdownStyle
            if style == 0, pos == 0, c.barInPhrase % 4 == 0 { add(.kick, 0.45) }
            if style == 2, pos == 0 { add(.kick, 0.35) }
            if style == 0, c.level > 0.08, pos % 4 == 2 { add(.hat, 0.15 + 0.2 * c.level) }
            if style == 3, pos % 2 == 0 { add(.hat, 0.12 + 0.2 * c.level) }
            // Drums pushed up stay in the breakdown: a soft kick on the one and the off-beat hats.
            if c.adds(.drums, 0x1D11) {
                if style != 0, style != 2, pos == 0 { add(.kick, 0.4) }
                if style != 0, style != 3, pos % 4 == 2 { add(.hat, 0.14 + 0.2 * c.level) }
            }
            if pos == 0 { add(low, 0.45, NoteParams(pitch: subPitch, lengthSteps: held(c.perBar))) }
            if pos == 8, c.adds(.bass, 0x1D12) {
                add(low, 0.35, NoteParams(pitch: subPitch, lengthSteps: held(c.perBar / 2)))
            }
            if style != 2, pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: style == 1 ? 0.42 : 0.3, add: add) }
            // Tropical house keeps its hook through the breakdown, softly, handed to a recorded sax or nylon guitar
            // (by the track's breakdown style) over the pads. Any other hook part pushed up keeps it too.
            if genre == .tropicalHouse {
                let voice = c.track.breakdownStyle % 2 == 0 ? KeysVoice.sampledSax : KeysVoice.sampledNylonGuitar
                keysHook(genre, c, velocity: 0.34, voice: voice, add: add)
            } else if c.adds(hookPart(genre), 0x1D13) {
                keysHook(genre, c, velocity: 0.34, add: add)
            }
        case .build:
            // The build ramps bar by bar across its whole planned length, not once per phrase (#40): the kick firms up
            // and fills in, the hats go from quarters to 8ths to 16ths, the snare tightens from the backbeat to a
            // 16th roll, and over the last bars the kit opens up (see `opening`).
            let t = c.buildProgress
            let kicks = !p.gentle && t >= 0.5 ? p.buildKicks + [4, 8, 12] : p.buildKicks
            if kicks.contains(pos) { add(.kick, (pos == 0 ? 0.7 : 0.55) + 0.25 * t) }
            let hatStride = t < 0.25 ? 4 : t < 0.6 ? 2 : 1
            if pos % hatStride == (hatStride == 4 ? 2 : 0) {
                add(.hat, (pos % 2 == 0 ? 0.22 : 0.14) + 0.2 * t + 0.1 * c.level)
            } else if t >= 0.5, c.adds(.drums, 0x1D21) {
                // Drums pushed up rush the second half of the build with the 16ths in between.
                add(.hat, 0.14 + 0.2 * t + 0.1 * c.level)
            }
            if p.gentle {
                if p.buildSnares.contains(pos) { add(.snare, 0.4 + 0.2 * t) }
            } else {
                // A genre that arrives on a quiet pickup tops out at 8ths, softly; the others roll in 16ths.
                let quiet = dropEntry(genre) == .pickup
                let every = t < 0.4 ? 0 : t < 0.65 ? 4 : t < 0.85 || quiet ? 2 : 1
                if every > 0, pos % every == 0 {
                    add(.snare, (quiet ? 0.35 + 0.35 * t : 0.45 + 0.45 * t) + 0.1 * Double(pos) / 16)
                } else if every == 0, p.buildSnares.contains(pos) {
                    add(.snare, 0.6 + 0.2 * t)
                }
            }
            if pos == 0 { add(low, 0.45 + 0.2 * t, NoteParams(pitch: subPitch, lengthSteps: held(c.perBar))) }
            // The hook, stated on keys and growing toward the drop.
            keysHook(genre, c, velocity: 0.3 + 0.35 * t, add: add)
        case .drop, .drop2:
            break
        }
        return out
    }

    /// The layers an intro adds once it has sat for two phrases, one more each phrase and then rotating, so a long
    /// intro never idles on one loop (a 39-bar riddim intro of one 2-bar loop was narduk-sound#40):
    /// a bass pulse on every bar (a bell while the input is too quiet for bass), off-beat ticks, a counter-note
    /// answering on the fifth, and a soft kick.
    private static func introLayers(
        _ genre: Genre, _ c: StepContext, pos: Int, subPitch: Int, add: (Instrument, Double, NoteParams) -> Void
    ) {
        guard c.phraseInSection >= 2 else { return }
        let rotation = c.phraseInSection - 2
        let layers: Set<Int> = rotation == 0 ? [0] : [rotation % 4, (rotation + 1) % 4]
        let band = isBand(genre)
        if layers.contains(0), pos == 0 {
            if c.level > 0.15 {
                add(
                    band ? .bassGuitar : .sub, 0.3 + 0.2 * c.level,
                    NoteParams(pitch: subPitch, lengthSteps: c.scaled(profile(genre).gentle ? 7 : 8)))
            } else {
                // Too quiet for a bass: a soft bell of the root an octave up marks the bar instead.
                let pitch = c.track.pitch(c.keyRoot + 12, degree: c.chord)
                if band {
                    add(guitars(genre).lead, 0.24, NoteParams(pitch: pitch, lengthSteps: c.scaled(4)))
                } else {
                    add(.keys, 0.22, NoteParams(pitch: pitch, lengthSteps: c.scaled(4), voice: c.track.keysVoice))
                }
            }
        }
        if layers.contains(1), pos % 4 == 2 { add(.hat, 0.1 + 0.15 * c.level, NoteParams()) }
        if layers.contains(2), c.barInPhrase % 2 == 1, pos == 8 {
            let pitch = c.track.pitch(c.keyRoot, degree: c.chord + 4)
            if band {
                add(guitars(genre).lead, 0.3, NoteParams(pitch: pitch, lengthSteps: c.scaled(6), drive: c.track.drive))
            } else {
                add(.keys, 0.26, NoteParams(pitch: pitch, lengthSteps: c.scaled(6), voice: c.track.keysVoice))
            }
        }
        if layers.contains(3), pos == 0 || (pos == 8 && c.barInPhrase % 2 == 1) { add(.kick, 0.4, NoteParams()) }
    }

    /// Soft pad chords (keys voice 3) on the bar's chord, two bars long.
    private static func pad(_ c: StepContext, velocity: Double, add: (Instrument, Double, NoteParams) -> Void) {
        let genre = c.track.genre
        if isBand(genre) {
            // A band has no pad: a soft guitar chord rings for the two bars instead.
            strum(genre, c, velocity: velocity * 1.4, length: 32, add: add)
            return
        }
        let voice = genre == .tropicalHouse ? KeysVoice.pumpPad : KeysVoice.pad
        let notes = chord(c, degree: c.chord, base: c.keyRoot - 12, seventh: Self.lush(c.track.genre))
        // Tropical house's chords are a recorded piano, the pumping pad a quieter bed beneath it.
        let padVelocity = genre == .tropicalHouse ? velocity * 0.6 : velocity
        for pitch in notes {
            add(.keys, padVelocity, NoteParams(pitch: pitch, lengthSteps: c.perBar * 2, voice: voice))
        }
        if genre == .tropicalHouse {
            for pitch in notes {
                add(.keys, velocity, NoteParams(pitch: pitch + 12, lengthSteps: c.perBar * 2, voice: KeysVoice.sampledPiano))
            }
        }
    }

    /// The hook on the track's keys: single notes, or chord stabs for house.
    private static func keysHook(
        _ genre: Genre, _ c: StepContext, velocity: Double, voice: Int? = nil,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        if isBand(genre) {
            guitarHook(genre, c, velocity: velocity, add: add)
            return
        }
        for note in c.hookNotes() {
            let accent = note.accent ? 1.0 : 0.82
            let degree = c.chord + note.degree
            if genre == .house || genre == .ukGarage {
                // House spreads each stab across the field, low note left and top note right: without it the drop's
                // mids measured as mono (mid-band side/mid 0.001 once the clap was out; records 0.57).
                let stab = chord(c, degree: degree, base: c.keyRoot)
                for (i, pitch) in stab.enumerated() {
                    let pan = genre == .house && stab.count > 1 ? 0.8 * Double(i) / Double(stab.count - 1) - 0.4 : 0
                    add(
                        .keys, velocity * accent,
                        NoteParams(pitch: pitch, lengthSteps: c.scaled(note.length), voice: 1, pan: pan)
                    )
                }
            } else {
                let low: Set<Genre> = [.chill, .drumAndBass, .lofi, .synthwave]
                let base = low.contains(genre) ? c.keyRoot : c.keyRoot + 12
                add(
                    .keys, velocity * accent,
                    NoteParams(
                        pitch: c.track.pitch(base, degree: degree), lengthSteps: c.scaled(note.length),
                        voice: voice ?? c.track.keysVoice))
            }
        }
    }

    /// Tropical house plays its drums' top on hand percussion (`PercussionVoice`): the hat on a shaker, the open hat on
    /// a tambourine, the snare on a finger snap (applied to every note `DropConductor` writes). Every other genre, and a
    /// note that already names a voice, is unchanged.
    static func percussion(_ genre: Genre, _ instrument: Instrument, _ params: NoteParams) -> NoteParams {
        guard genre == .tropicalHouse, params.voice == nil else { return params }
        var params = params
        switch instrument {
        case .hat: params.voice = PercussionVoice.shaker
        case .openHat: params.voice = PercussionVoice.tambourine
        case .snare: params.voice = PercussionVoice.snap
        default: break
        }
        return params
    }

    /// A level trim per part, against the arrangement's own velocities. Tropical house is a melody track with the bass
    /// under it: the first blind test (2026-10-07) heard the bassline tower over the flutes and the drums hit too hard,
    /// and the song measured 10-20 dB less melody against its bass than a reference track. The recorded melody comes
    /// up in its own trims (`SampledInstrument.trim`); the low end and the kick come down here.
    ///
    /// House's clap came in nearly as loud as the whole mix (peak 0.62 against 0.71 on its own), and its noise was most of
    /// the drop's energy above 2 kHz: without it the spectral centroid fell from 5.5 kHz to 1.7 kHz (records: 2.9 kHz).
    static func balance(_ genre: Genre, _ instrument: Instrument) -> Double {
        switch (genre, instrument) {
        case (.tropicalHouse, .sub), (.tropicalHouse, .wobble), (.tropicalHouse, .bassGuitar): 0.8
        case (.tropicalHouse, .kick): 0.4
        case (.tropicalHouse, .snare): 0.8
        case (.house, .snare): 0.5
        default: 1
        }
    }

    /// The breakdown's vocal lead: the hook's long notes on vox, an octave down from the keys.
    static func lead(_ c: StepContext) -> [ScheduledNote] {
        // The formant vox is an electronic sound: in a band's breakdown it was the loudest thing and did not belong
        // (Logan's flag 6, funk, 2026-10-07). Tropical house has none either: its low formant sweep reads as a whomp
        // under the pluck.
        // Vocals pushed up sing the lead through the build's first half and the intro's hook too.
        let early = (c.section == .build && c.barInPhrase < c.barsPerPhrase / 2) || (c.section == .intro && c.introHook)
        let more = early && c.adds(.vocals, 0x5E01)
        guard c.section == .breakdown || more, !isBand(c.track.genre), !profile(c.track.genre).gentle else { return [] }
        return c.hookNotes().filter { $0.length >= 3 }.map { note in
            let pitch = c.track.pitch(c.keyRoot - 12, degree: c.chord + note.degree)
            return ScheduledNote(
                step: c.step, instrument: .vox, velocity: 0.42,
                params: NoteParams(pitch: pitch, lengthSteps: c.scaled(note.length), voice: c.track.vowel))
        }
    }

    // MARK: The drop

    /// What one drop bar changes against the bar it would otherwise repeat (#40: a dubstep drop played one bar 16
    /// times). The phrase is a call and a response: the first half plays the groove, the second answers it with a
    /// bass rhythm variant and a hat pattern swap; the half-phrase bar drops out where the track has no mid fill.
    struct BarVariation: Equatable {
        /// The hats swap their accents to the off-beats and add 16th pickups and an open hat on the last 8th.
        var hatSwap = false
        /// The bass answers: notes half as long (a legato line keeps its lengths), the second half of the bar an octave
        /// up (the sub stays where it is).
        var bassVariant = false
        /// The hats drop out for the second half of the bar.
        var dropOut = false
    }

    /// The bar's variation, a pure function of the phrase plan and the bar. How the response answers is seeded per
    /// phrase; that it answers at all is not, so no bar or pair of bars repeats more than four bars running.
    static func variation(_ c: StepContext) -> BarVariation {
        var v = BarVariation()
        guard c.barsPerPhrase >= 4, !c.isLastBar else { return v }
        let half = c.barsPerPhrase / 2
        // Trap's 808 already slides in its own register; its response is the hats.
        let answer = c.track.genre == .trap ? 2 : c.plan.bits(0, 0x5EC7_10) % 3
        if c.barInPhrase >= half {
            let index = c.barInPhrase - half
            switch answer {
            case 0: v.bassVariant = true
            case 1:
                v.bassVariant = index % 2 == 0
                v.hatSwap = index % 2 == 1
            default:
                v.bassVariant = index == 0
                v.hatSwap = true
            }
        } else if c.isHalfPhraseBar {
            v.dropOut = c.plan.midFill == nil
        } else if c.barInPhrase == half - 2, answer != 2 {
            v.hatSwap = c.plan.bits(c.bar, 0x4A75) % 3 == 0
        }
        return v
    }

    /// Drums, bass and keys for one step of a drop section.
    static func drop(_ genre: Genre, _ c: StepContext) -> [ScheduledNote] {
        guard let pos = c.pos else { return [] }
        var out: [ScheduledNote] = []
        let variation = variation(c)
        let legato = (profile(genre).glide ?? 0) >= 0.3
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams) {
            var params = params
            if params.delay == nil { params.delay = c.swing(pos) }
            if variation.bassVariant, genre != .trap, [.wobble, .sub, .bassGuitar].contains(instrument) {
                // A legato line (a gliding reese) keeps its lengths, so its notes still touch end to start.
                if !legato { params.lengthSteps = max(1, params.lengthSteps / 2) }
                if instrument != .sub, pos >= 8, let pitch = params.pitch { params.pitch = pitch + 12 }
            }
            out.append(
                ScheduledNote(step: c.step, instrument: instrument, velocity: min(1, max(0, velocity)), params: params))
        }
        let fill = activeFill(c, pos: pos)
        drums(genre, c, pos: pos, fill: fill, variation: variation, add: add)
        bass(genre, c, pos: pos, fill: fill, add: add)
        keys(genre, c, pos: pos, fill: fill, add: add)
        counterLine(genre, c, pos: pos, fill: fill, add: add)
        return out
    }

    /// Whether a genre's drop already writes its hook part (keys, or the band's guitar) in this section.
    static func dropHasHookPart(_ genre: Genre, _ section: SongSection) -> Bool {
        switch genre {
        case .riddim: false
        case .dubstep: section == .drop2
        default: true
        }
    }

    /// The hook part pushed above 1, in a drop that already has it: extra chord stabs on the off-beats around the hook
    /// and a counter-line answering it on the fifth. Keys stab on electric piano; a band strums and picks the lead.
    private static func counterLine(
        _ genre: Genre, _ c: StepContext, pos: Int, fill: (kind: Fill, from: Int)?,
        add: (Instrument, Double, NoteParams) -> Void
    ) {
        let part = hookPart(genre)
        guard c.emphasis.lift(part) > 0, c.outro != .drumBridge, dropHasHookPart(genre, c.section) else { return }
        if let fill, fill.kind == .kickDrop, pos >= fill.from { return }
        let hooked = !c.hookNotes().isEmpty
        if pos == 6 || pos == 14, !hooked, c.adds(part, 0x2C01) {
            if isBand(genre) {
                strum(genre, c, velocity: 0.42, length: 1, up: true, add: add)
            } else {
                for pitch in chord(c, degree: c.chord, base: c.keyRoot, seventh: lush(genre)) {
                    add(.keys, 0.3, NoteParams(pitch: pitch, lengthSteps: c.scaled(1), voice: 2))
                }
            }
        }
        if pos == 4 || pos == 12, !hooked, c.emphasis.lift(part) >= 0.5, c.adds(part, 0x2C02 &+ UInt64(pos)) {
            let degree = c.chord + (pos == 4 ? 4 : 2)
            let instrument: Instrument = isBand(genre) ? guitars(genre).lead : .keys
            let params =
                isBand(genre)
                ? NoteParams(
                    pitch: c.track.pitch(c.keyRoot + 12, degree: degree), lengthSteps: c.scaled(2), drive: c.track.drive)
                : NoteParams(pitch: c.track.pitch(c.keyRoot + 12, degree: degree), lengthSteps: c.scaled(2), voice: 2)
            add(instrument, 0.34, params)
        }
    }

    /// The fill acting at this position, with where its zone starts (the last bar's, or the half-phrase's last beat).
    static func activeFill(_ c: StepContext, pos: Int) -> (kind: Fill, from: Int)? {
        guard let fill = writtenFill(c) else {
            // Drums pushed up add a snare-roll fill at the half phrase where the track has none.
            return c.isHalfPhraseBar && c.adds(.drums, 0x3F12) ? (.snareRoll, 12) : nil
        }
        // A part held down skips some of its fills: the bass its stutter, the drums the rest.
        let weight = c.emphasis[fill.kind == .bassStutter ? .bass : .drums]
        return weight < 1 && c.draw(0x3F11) >= weight ? nil : fill
    }

    /// The fill the track writes here, before any emphasis.
    private static func writtenFill(_ c: StepContext) -> (kind: Fill, from: Int)? {
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
        _ genre: Genre, _ c: StepContext, pos: Int, fill: (kind: Fill, from: Int)?, variation: BarVariation,
        add emit: (Instrument, Double, NoteParams) -> Void
    ) {
        var hatted = false
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams) {
            var params = params
            var velocity = velocity
            if params.formant == nil { params.formant = c.track.drumTune(instrument) }
            if instrument == .hat || instrument == .openHat {
                if variation.dropOut, pos >= 8 { return }
                if instrument == .hat {
                    hatted = true
                    if variation.hatSwap { velocity *= pos % 4 == 2 ? 1.35 : 0.75 }
                }
            }
            emit(instrument, velocity, params)
        }
        let variant = c.track.kit(drop2: c.section == .drop2)
        let level = c.level
        let soft = genre == .chill || genre == .lofi || genre == .folk
        let driving = genre == .house || genre == .techno || genre == .tropicalHouse
        let inFill = fill.map { pos >= $0.from } ?? false
        let kind = inFill ? fill?.kind : nil
        let main = c.isLastBar  // the half-phrase fill only whispers

        var kicks = c.barInPhrase % 2 == 0 ? variant.kicksA : variant.kicksB
        var snares = variant.snares
        if kind == .halfTime || c.track.halfTime {
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
            let velocity =
                genre == .tropicalHouse
                ? 0.7
                : pos == 0 ? (soft ? 0.7 : 1.0) : (soft ? 0.4 : driving ? 0.95 : genre == .synthwave ? 0.9 : 0.75)
            add(.kick, velocity, NoteParams())
        }

        let snareVelocity =
            soft || genre == .tropicalHouse
            ? 0.5 : genre == .house ? 0.75 : genre == .techno ? 0.55 : genre == .synthwave ? 0.9 : 1.0
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
        var ghostChance = c.track.ghostDensity * (genre == .drumAndBass ? 1 : 0.4 + 0.6 * level)
        if c.emphasis[.drums] != 1 { ghostChance = min(1, ghostChance * c.emphasis[.drums]) }
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
        case .chill, .lofi:
            // Soft swung 16ths: the off-16ths lean late (the swing) and quiet.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.22 : 0.12) + 0.12 * level, NoteParams()) }
            if pos % 4 == 3 { add(.hat, 0.1 + 0.08 * level, NoteParams()) }
        case .techno:
            // Closed 16ths ticking under the off-beat open hats; energy only adds the in-between ones.
            if pos % 4 == 2 { add(.hat, 0.3 + 0.15 * level, NoteParams()) }
            if pos % 2 == 0 && pos % 4 != 2 { add(.hat, 0.14 + 0.1 * level, NoteParams()) }
            if level > 0.5, pos % 2 == 1 { add(.hat, 0.08 + 0.08 * level, NoteParams()) }
        case .ukGarage:
            // Shuffled 16ths: the swing pushes the off-16ths late; every 8th is a touch louder.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.3 : 0.2) + 0.15 * level, NoteParams()) }
            if pos % 4 == 3 { add(.hat, 0.12 + 0.1 * level, NoteParams()) }
        case .synthwave:
            // Straight 8ths, the off-beat ones leaning in.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.34 : 0.22) + 0.2 * level, NoteParams()) }
        case .rock:
            // Straight 8ths on the hat, the off-beat ones a touch harder.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.36 : 0.28) + 0.2 * level, NoteParams()) }
        case .folk:
            // A shaker on the off-beats and nothing else.
            if pos % 4 == 2 { add(.hat, 0.14 + 0.1 * level, NoteParams()) }
        case .funk:
            // Tight 16ths, the off-beats accented, the in-between ones ghosted.
            if pos % 2 == 0 { add(.hat, (pos % 4 == 2 ? 0.36 : 0.26) + 0.2 * level, NoteParams()) }
            if pos % 2 == 1, level > 0.3 { add(.hat, 0.12 + 0.1 * level, NoteParams()) }
        case .tropicalHouse:
            // A shaker: the off-beat 8th leans in, the 16ths around it whisper.
            if pos % 4 == 2 { add(.hat, 0.24 + 0.1 * level, NoteParams()) }
            if pos % 2 == 1 { add(.hat, 0.08 + 0.06 * level, NoteParams()) }
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
        if variant.openHats.contains(pos), driving || level > 0.6, kind != .kickDrop {
            // Tropical house's open hat is a light tambourine-like lift, not a wash.
            add(.openHat, genre == .tropicalHouse ? 0.3 + 0.15 * level : 0.55 + 0.25 * level, NoteParams())
        } else if pos == 14, kind != .kickDrop, !variation.hatSwap, c.barInPhrase % 2 == 1, c.adds(.drums, 0x3F21) {
            // Drums pushed up lift every other bar with an open hat into the next.
            add(.openHat, genre == .tropicalHouse ? 0.25 + 0.1 * level : 0.45 + 0.25 * level, NoteParams())
        }
        if variation.hatSwap {
            // The swapped pattern: 16th pickups into beats 2 and 4, and an open hat on the bar's last 8th.
            if !hatted, pos == 3 || pos == 11 { add(.hat, 0.18 + 0.12 * level, NoteParams()) }
            if pos == 14, !variant.openHats.contains(14), variant.openHats.count < 2 {
                add(.openHat, genre == .tropicalHouse ? 0.25 + 0.1 * level : 0.4 + 0.2 * level, NoteParams())
            }
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
            if isBand(genre) {
                add(
                    .bassGuitar, 0.85,
                    NoteParams(
                        pitch: bassRegister(track.pitch(wobbleBase, degree: c.chord)) + (pos % 2 == 1 ? 12 : 0),
                        lengthSteps: c.scaled(1), drive: 0.4))
            } else if genre == .trap {
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

        // Bass pushed up answers the bar with a short octave on the last 8th, on the genre's own bass instrument.
        if pos == 14, c.adds(.bass, 0x4B01) {
            if isBand(genre) {
                add(
                    .bassGuitar, 0.6,
                    NoteParams(
                        pitch: bassRegister(track.pitch(wobbleBase, degree: c.chord)) + 12, lengthSteps: length(1),
                        drive: 0.3))
            } else {
                add(
                    .sub, 0.6,
                    NoteParams(pitch: subRegister(track.pitch(c.keyRoot - 36, degree: c.chord) + 12), lengthSteps: length(1)))
            }
        }
        if isBand(genre) {
            bandBass(genre, c, pos: pos, length: length, add: add)
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
            // The sub sits an octave above the other genres' (55-125 Hz): at keyRoot - 36 it lived under 60 Hz with
            // the kick's fundamental and left the 60-250 Hz bass band to the kick alone (record-loop, 2026-10-08).
            if pos % 4 == 2 {
                let octave = pos == 6 || pos == 14 ? 12 : 0
                add(.sub, 0.85, NoteParams(pitch: subPitch + 12, lengthSteps: length(2)))
                wobble(track.pitch(wobbleBase, degree: c.chord) + octave, 2, velocity: 0.7, accent: pos == 2)
            }
        case .trap:
            break
        case .techno:
            // A rolling rumble: a short sub on three of every four 16ths (the kick owns the fourth), with a muted
            // wub on each off-beat.
            // The last 16th of the bar leans to the fifth, so the rumble turns round at the bar line.
            if pos % 4 != 0 {
                let pitch = pos == 15 ? track.pitch(c.keyRoot - 36, degree: c.chord + 4) : subPitch
                add(.sub, pos % 4 == 2 ? 0.85 : 0.5, NoteParams(pitch: pitch, lengthSteps: length(1)))
            }
            if pos % 4 == 2 { wobble(track.pitch(wobbleBase, degree: c.chord), 1, velocity: 0.55, accent: pos == 10) }
        case .ukGarage:
            // A skippy, syncopated bass: long on the one, then short answers around the 2-step kick.
            let steps: [Int: Int] = [0: 6, 6: 3, 10: 4, 14: 2]
            if let steps = steps[pos] {
                let octave = pos == 14 ? 12 : 0
                add(.sub, pos == 0 ? 0.85 : 0.7, NoteParams(pitch: subPitch + octave, lengthSteps: length(steps)))
                if pos == 6 || pos == 14 {
                    // The answer on the 14 climbs a third, not an octave, so the line's contour follows the chord.
                    let degree = pos == 14 ? c.chord + 2 : c.chord
                    wobble(track.pitch(wobbleBase, degree: degree), 2, velocity: 0.55, accent: pos == 6)
                }
            }
        case .synthwave:
            // Driving 8ths: the root, then the octave, the way an arpeggiator pulse sits under a lead.
            if pos % 2 == 0 {
                let octave = pos % 4 == 2 ? 12 : 0
                wobble(track.pitch(wobbleBase, degree: c.chord) + octave, 2, velocity: 0.6, accent: pos % 8 == 0)
            }
            if pos == 0 || pos == 8 { add(.sub, 0.7, NoteParams(pitch: subPitch, lengthSteps: length(8))) }
        case .lofi:
            // A round, late sub on the boom-bap kicks.
            if pos == 0 { add(.sub, 0.65, NoteParams(pitch: subPitch, lengthSteps: length(10))) }
            if pos == 10 {
                let pitch = track.pitch(c.keyRoot - 36, degree: c.chord + (c.chord % 2 == 0 ? 2 : 4))
                add(.sub, 0.5, NoteParams(pitch: pitch, lengthSteps: length(6)))
            }
        case .tropicalHouse:
            // A round off-beat sub on every "and", the last one of an odd bar on the fifth. No wobble (take one's soft
            // wub was the whomp) and no glide: each note is short, so the next starts fresh at its own pitch.
            if pos % 4 == 2 {
                let turn = pos == 14 && c.barInPhrase % 2 == 1
                let pitch = turn ? track.pitch(c.keyRoot - 36, degree: c.chord + 4) : subPitch
                add(.sub, 0.8, NoteParams(pitch: pitch, lengthSteps: length(2)))
            }
        case .rock, .folk, .funk:
            break  // the band's bass guitar is written above
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
        case .house, .techno, .ukGarage, .synthwave, .lofi, .rock, .folk, .funk, .tropicalHouse:
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
        case .techno:
            keysHook(genre, c, velocity: 0.5, add: add)
        case .ukGarage:
            keysHook(genre, c, velocity: 0.5, add: add)
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.22, add: add) }
        case .synthwave:
            // A lead over a held pad: the hook's long notes ring, the chords underneath move every two bars.
            keysHook(genre, c, velocity: 0.52, add: add)
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.3, add: add) }
        case .lofi:
            keysHook(genre, c, velocity: 0.45, add: add)
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.24, add: add) }
        case .tropicalHouse:
            // Four bars at a time: the pluck calls for two, the vocal chops answer in the third (`VocalLine`), and
            // the fourth rests on the groove with a conga or two. Piano chords and the pumping pad underneath.
            let call = c.barInPhrase % 4
            if call < 2 { keysHook(genre, c, velocity: 0.6, add: add) }
            if call == 3, !c.isLastBar {
                if pos == 10 { add(.keys, 0.42, NoteParams(pitch: 64, lengthSteps: 2, voice: KeysVoice.sampledConga)) }
                if pos == 14 { add(.keys, 0.5, NoteParams(pitch: 55, lengthSteps: 2, voice: KeysVoice.sampledConga)) }
            }
            if pos == 0, c.barInPhrase % 2 == 0 { pad(c, velocity: 0.32, add: add) }
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
        case .rock, .folk, .funk:
            // The guitar is the chord layer; a kick drop silences it with the bass, and the hook joins in DROP2.
            if let fill, fill.kind == .kickDrop, pos >= fill.from { return }
            rhythmGuitar(genre, c, pos: pos, add: add)
            if c.section == .drop2 { keysHook(genre, c, velocity: 0.5, add: add) }
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
