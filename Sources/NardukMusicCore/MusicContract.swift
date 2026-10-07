import Foundation

// The shared music contract. Signals go in (MusicSignal.swift); the conductor writes ScheduledNotes on a 16th-note
// grid; the synth (NardukMusicDSP) plays them and publishes a VisualizerFrame; ConductorSnapshot says what is playing
// and why. Every type here is a plain Sendable value, so a source, the conductor and the audio engine can each own a
// copy on their own thread.

// MARK: - Music

public enum SongSection: String, Sendable, Hashable, Codable, CaseIterable {
    case intro, build, drop, breakdown, drop2
}

public enum Genre: String, Sendable, Hashable, Codable, CaseIterable {
    case dubstep, riddim, drumAndBass, trap, house, chill
    /// The second electronic wave (narduk-libs#1577): each its own tempo, drum grammar and bass patch.
    case techno, ukGarage, synthwave, lofi
    /// The band family (narduk-libs#1578): the guitars carry the part over a live-drummer kit and a bass guitar.
    /// Rock drives power chords, folk strums and picks an acoustic, funk scratches muted 16ths over a popping bass.
    case rock, folk, funk
}

public enum Instrument: String, Sendable, Hashable, Codable, CaseIterable {
    case kick, snare, hat, openHat, wobble, sub, glitch, scratch, laser, vox, riser, tapeStop, impact
    /// Pitched keys for hooks and harmony: `voice` picks the timbre (0 bell pluck, 1 house stab, 2 electric piano, 3 pad).
    case keys
    /// Karplus-Strong plucked strings (narduk-libs#1574). `pitch` is the note; `drive` (electric guitar) is 0 ... 1.
    case acousticGuitar, electricGuitar, bassGuitar
    /// Six strings struck in a staggered sweep on a chord from a fixed set. `pitch` is the chord root (folded into the
    /// guitar's low range), `voice` picks the chord (`voice % 6`: major, minor, dominant 7, minor 7, power, sus2), and
    /// `formant` of 0.5 or more strums up instead of down. `strum` is acoustic; `electricStrum` takes `drive`.
    case strum, electricStrum
    /// A wordless female-range voice (narduk-libs#1641), formant-synthesised. `pitch` is the note and `formant` its
    /// register (0 alto ... 1 soprano, 0.5 absent). `voice` packs the vowel and style (see `VocalVowel`, `VocalStyle`):
    /// `voice & 7` is the vowel (ah, oh, oo, eh, ee, mm) and `(voice >> 3) & 3` the style (0 choir pad of three voices,
    /// 1 solo lead, 2 solo pad). `drive` is breathiness, 0 ... 1.
    case vocal
    /// A short vocal one-shot, the "chop" of a vocal sample: a soft consonant onset into a vowel, gated by
    /// `lengthSteps`. `pitch`, `voice` (vowel in `voice & 7`), `formant` and `drive` as for `vocal`.
    case vocalChop
    /// A cut in the master (narduk-libs#1641): the song is chopped, stuttered, gated or reversed for `lengthSteps` and
    /// then comes back. `voice` packs the mode and a seed, `formant` the division and `drive` the amount; build one with
    /// `NoteParams.cut(_:division:steps:amount:seed:)` (see `CutMode`, `CutDivision`).
    case cut
    /// A sampled female voice (narduk-libs#1641): real recorded ahs, oohs and runs (VocalSet, CC BY 4.0), key-mapped,
    /// looped and pitched by the sampler. `pitch` is the note. `voice` packs the vowel (`voice & 7`, as `vocal`), the
    /// technique (`(voice >> 3) & 3`: straight, vibrato, belt) and the kind (`(voice >> 5) & 3`: a held sustain, a
    /// syllable chop whose slice is `formant` 0 ... 1, or a whole scale run fitted to `lengthSteps`); build one with
    /// `NoteParams.sampleVoice(_:technique:kind:)`. `drive` is a gain trim, 0 ... 1 (absent: 0.8).
    case vocalSample
}

/// How a `vocalSample` note is sung.
public enum SampleTechnique: String, Sendable, Hashable, Codable, CaseIterable {
    case straight, vibrato, belt

    public var index: Int { SampleTechnique.allCases.firstIndex(of: self) ?? 0 }

    public init(voice: Int) {
        let i = (voice >> 3) & 3
        self = i < SampleTechnique.allCases.count ? SampleTechnique.allCases[i] : .vibrato
    }
}

/// What a `vocalSample` note plays.
public enum SampleKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A held vowel, looped for as long as the note lasts.
    case sustain
    /// A short syllable cut from a sung phrase, played once (`formant` picks the slice).
    case chop
    /// A fast sung scale, stretched or squeezed to fit the note's length.
    case run

    public var index: Int { SampleKind.allCases.firstIndex(of: self) ?? 0 }

    public init(voice: Int) {
        let i = (voice >> 5) & 3
        self = i < SampleKind.allCases.count ? SampleKind.allCases[i] : .sustain
    }
}

extension NoteParams {
    /// The `voice` field of a `vocalSample` note.
    public static func sampleVoice(
        _ vowel: VocalVowel = .ah, technique: SampleTechnique = .vibrato, kind: SampleKind = .sustain
    ) -> Int {
        vowel.index | technique.index << 3 | kind.index << 5
    }
}

/// What a `cut` does to the song while it lasts.
public enum CutMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Beat repeat: the last slice of the song, over and over. `amount` pitches it up and fades it as it repeats.
    case stutter
    /// A trance gate: the song chopped on and off once a slice. `amount` is how short the open part is.
    case gate
    /// The last slice played backwards, over and over.
    case reverse
    /// The last eight slices re-sequenced in a seeded order, a few left silent: a vocal-chop re-cut. `amount` is how
    /// many are silent.
    case chop

    public var index: Int { CutMode.allCases.firstIndex(of: self) ?? 0 }
}

/// How long one slice of a `cut` is (a repeat of this length lands on the beat grid).
public enum CutDivision: String, Sendable, Hashable, Codable, CaseIterable {
    case quarter, eighth, sixteenth, sixteenthTriplet, thirtySecond

    /// The slice's length in sixteenth-note steps.
    public var steps: Double {
        switch self {
        case .quarter: 4
        case .eighth: 2
        case .sixteenth: 1
        case .sixteenthTriplet: 2.0 / 3.0
        case .thirtySecond: 0.5
        }
    }

    public var index: Int { CutDivision.allCases.firstIndex(of: self) ?? 0 }

    /// The `NoteParams.formant` value that carries this division.
    public var formant: Double { Double(index) / Double(CutDivision.allCases.count - 1) }

    public init(formant: Double) {
        let all = CutDivision.allCases
        let i = Int((min(max(formant, 0), 1) * Double(all.count - 1)).rounded())
        self = all[i]
    }
}

extension NoteParams {
    /// The parameters of a `cut` note of `steps` sixteenths.
    public static func cut(
        _ mode: CutMode, division: CutDivision = .sixteenth, steps: Int = 2, amount: Double = 0.5, seed: Int = 0
    ) -> NoteParams {
        NoteParams(
            lengthSteps: max(steps, 1), formant: division.formant, drive: min(max(amount, 0), 1),
            voice: mode.index | (seed & 0xFFFFF) << 4)
    }
}

/// The vowels a `vocal` or `vocalChop` note sings (`NoteParams.voice & 7`; larger values fold back).
public enum VocalVowel: String, Sendable, Hashable, Codable, CaseIterable {
    case ah, oh, oo, eh, ee, mm

    /// The value `NoteParams.voice & 7` carries.
    public var index: Int { VocalVowel.allCases.firstIndex(of: self) ?? 0 }
}

/// How a `vocal` note is sung (`(NoteParams.voice >> 3) & 3`).
public enum VocalStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// Three detuned voices spread across the stereo field, slow attack and release: the "aah" pad.
    case choir
    /// One voice, a quicker attack and a scoop up to the pitch.
    case lead
    /// One voice with the pad's slow attack and release.
    case solo

    /// The value `(NoteParams.voice >> 3) & 3` carries.
    public var index: Int { VocalStyle.allCases.firstIndex(of: self) ?? 0 }

    /// The style a `voice` field asks for (an unknown value is a choir).
    public init(voice: Int) {
        let i = (voice >> 3) & 3
        self = i < VocalStyle.allCases.count ? VocalStyle.allCases[i] : .choir
    }
}

/// A voice character: presets of the same formant synthesiser that differ in formants, breath, vibrato, attack, voice
/// count and room (`(NoteParams.voice >> 5) & 15`; 0, `classic`, is the original voice).
public enum VocalFeel: String, Sendable, Hashable, Codable, CaseIterable {
    /// The original voice: a warm, even choir.
    case classic
    /// A breathy whisper pad: high breath, almost no vibrato, a soft slow attack.
    case airy
    /// A bright pop lead: soprano, forward upper formants, a fast scoop and a tight quick vibrato.
    case pop
    /// A dark, low hum: rounded and low-passed.
    case dark
    /// A gospel or soul belt: a wide slow vibrato, grit, and big slides up to the note.
    case soul
    /// An ethereal choir: five detuned voices, a long room, the vowel drifting from one to the next.
    case ethereal
    /// A playful "la la": higher formants, quick, bright and short.
    case toy
    /// A powerful, slightly coarse chest-mix belt: a strong first formant, a forward singer's formant, a little grit.
    case power
    /// A riff voice for fast melismatic runs (`VocalRun`): clean, quick, a tight vibrato for the held end of a run.
    case runs

    public var index: Int { VocalFeel.allCases.firstIndex(of: self) ?? 0 }

    /// The feel a `voice` field asks for (an unknown value is `classic`).
    public init(voice: Int) {
        let i = (voice >> 5) & 15
        self = i < VocalFeel.allCases.count ? VocalFeel.allCases[i] : .classic
    }
}

extension NoteParams {
    /// The `voice` value that sings `vowel` in `style` and `feel`.
    public static func vocalVoice(_ vowel: VocalVowel, style: VocalStyle = .choir, feel: VocalFeel = .classic) -> Int {
        vowel.index | style.index << 3 | feel.index << 5
    }
}

/// Musical LFO rate for the wobble, as a note division.
public enum WobbleRate: String, Sendable, Hashable, Codable, CaseIterable {
    case half, quarter, eighth, eighthTriplet, sixteenth, sixteenthTriplet

    /// LFO cycles per beat.
    public var cyclesPerBeat: Double {
        switch self {
        case .half: 0.5
        case .quarter: 1
        case .eighth: 2
        case .eighthTriplet: 3
        case .sixteenth: 4
        case .sixteenthTriplet: 6
        }
    }
}

/// Continuous parameters a note may carry; instruments ignore what they don't use.
public struct NoteParams: Sendable, Hashable, Codable {
    /// MIDI note number (bass and pitched FX); nil for unpitched drums.
    public var pitch: Int?
    /// Note length in 16th-note steps.
    public var lengthSteps: Int = 1
    public var wobbleRate: WobbleRate?
    /// 0 (dark "yoi") ... 1 (bright "wub").
    public var formant: Double?
    /// 0 ... 1 drive/distortion amount.
    public var drive: Double?
    /// Stable bass patch index derived from the top app (hash of its bundle ID).
    public var voice: Int?
    /// -1 (left / inbound) ... 1 (right / outbound).
    public var pan: Double = 0
    /// 0 ... 1 portamento into this note from a note it overlaps (bass voices): 0 is the engine's short default
    /// (~35 ms), 1 a slow ~250 ms slide. Ignored when the note does not start legato.
    public var glide: Double?
    /// 0 ... 0.5 of a step the note sounds late (swing on the off-16ths); nil is on the grid.
    public var delay: Double?
    /// A `vocalSample` note's packed `VocalExpression` (vibrato, scoops, morph, formant shift, echo and the rest); nil
    /// or 0 is a plain note. Build it with `NoteParams.expressed(_:)`.
    public var expression: Int?

    public init(
        pitch: Int? = nil, lengthSteps: Int = 1, wobbleRate: WobbleRate? = nil, formant: Double? = nil,
        drive: Double? = nil, voice: Int? = nil, pan: Double = 0, glide: Double? = nil, delay: Double? = nil,
        expression: Int? = nil
    ) {
        self.expression = expression
        self.pitch = pitch
        self.lengthSteps = lengthSteps
        self.wobbleRate = wobbleRate
        self.formant = formant
        self.drive = drive
        self.voice = voice
        self.pan = pan
        self.glide = glide
        self.delay = delay
    }
}

/// A note the conductor has placed on the grid. Time is in 16th-note steps from the
/// start of the song, so the audio engine maps it to sample time with its own clock.
public struct ScheduledNote: Sendable, Hashable, Codable {
    /// Absolute 16th-note step index since song start (always an integer grid position).
    public var step: Int
    public var instrument: Instrument
    /// 0 ... 1
    public var velocity: Double
    public var params: NoteParams

    public init(step: Int, instrument: Instrument, velocity: Double, params: NoteParams = NoteParams()) {
        self.step = step
        self.instrument = instrument
        self.velocity = velocity
        self.params = params
    }
}

public struct SongSettings: Sendable, Hashable, Codable {
    public var bpm: Double = 140
    public var genre: Genre = .dubstep
    /// MIDI root of the key (65 = F4; F minor by default).
    public var keyRoot: Int = 65
    public var stepsPerBar: Int = 16
    public var barsPerPhrase: Int = 8
    /// Seeds every track of the song. Fixed for tests; the app draws a fresh one per play (`sessionSeed`).
    public var seed: UInt64 = 0x5EED
    /// The kind of music the song is (`electronic` today for every genre). A family may set song-shape defaults
    /// (`GenreFamily.shape`) that the fields below override.
    public var family: GenreFamily = .electronic
    /// Pins every track to this mode (a major key, say); nil lets each track pick from the genre and the input, as
    /// before. Takes effect from the next track.
    public var mode: HarmonyMode?
    /// How chords are voiced; nil leaves it to the family, then to the genre's own arrangement.
    public var voicing: ChordVoicing?
    /// A chord layer (strum, stabs, arpeggio, held chords) over the arrangement; nil leaves it to the family.
    public var comping: CompingPattern?
    /// 0 ... 1: how far a song's seed reaches beyond the genre's hand-written banks (narduk-libs#1617). Each axis the
    /// generators cover (chord progression, hook motif, and as they land drum grammar, arrangement and timbre) draws
    /// generated material with this probability, from a stream derived from the seed that never disturbs the
    /// original draw order. 0 is the original single-template-per-genre song, bit for bit; settings saved before this
    /// field existed decode as 0.
    public var variety: Double = 0.75

    public init(
        bpm: Double = 140, genre: Genre = .dubstep, keyRoot: Int = 65, stepsPerBar: Int = 16, barsPerPhrase: Int = 8,
        seed: UInt64 = 0x5EED, family: GenreFamily = .electronic, mode: HarmonyMode? = nil,
        voicing: ChordVoicing? = nil, comping: CompingPattern? = nil, variety: Double = 0.75
    ) {
        self.bpm = bpm
        self.genre = genre
        self.keyRoot = keyRoot
        self.stepsPerBar = stepsPerBar
        self.barsPerPhrase = barsPerPhrase
        self.seed = seed
        self.family = family
        self.mode = mode
        self.voicing = voicing
        self.comping = comping
        self.variety = min(1, max(0, variety.isFinite ? variety : 0))
    }

    /// Settings saved before the harmony fields existed decode with those fields unset.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bpm: try container.decode(Double.self, forKey: .bpm),
            genre: try container.decode(Genre.self, forKey: .genre),
            keyRoot: try container.decode(Int.self, forKey: .keyRoot),
            stepsPerBar: try container.decode(Int.self, forKey: .stepsPerBar),
            barsPerPhrase: try container.decode(Int.self, forKey: .barsPerPhrase),
            seed: try container.decode(UInt64.self, forKey: .seed),
            family: try container.decodeIfPresent(GenreFamily.self, forKey: .family) ?? .electronic,
            mode: try container.decodeIfPresent(HarmonyMode.self, forKey: .mode),
            voicing: try container.decodeIfPresent(ChordVoicing.self, forKey: .voicing),
            comping: try container.decodeIfPresent(CompingPattern.self, forKey: .comping),
            variety: try container.decodeIfPresent(Double.self, forKey: .variety) ?? 0)
    }

    /// A seed for a new play session, from the wall clock, so two sessions write different songs.
    public static func sessionSeed(now: Date = Date()) -> UInt64 {
        var mix = UInt64(bitPattern: Int64((now.timeIntervalSince1970 * 1_000).rounded()))
        mix = (mix ^ (mix >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        return mix ^ (mix >> 29)
    }

    /// The voicing in effect: the setting, else the family's.
    public var effectiveVoicing: ChordVoicing? { voicing ?? family.shape.voicing }
    /// The comping pattern in effect: the setting, else the family's.
    public var effectiveComping: CompingPattern? { comping ?? family.shape.comping }

    public var secondsPerStep: Double { 60.0 / bpm / 4.0 }
    public var stepsPerPhrase: Int { stepsPerBar * barsPerPhrase }
}

/// What the UI shows about the song; published by the conductor roughly once per step.
public struct ConductorSnapshot: Sendable, Hashable, Codable {
    public var section: SongSection = .intro
    public var step: Int = 0
    /// 0 ... 1 smoothed energy.
    public var energy: Double = 0
    public var buildThreshold: Double = 0.55
    public var dropThreshold: Double = 0.4
    public var wobbleRate: WobbleRate = .quarter
    public var dropQueued: Bool = false
    /// What drove recent notes, for the "what you're hearing" legend.
    public var legend: [String] = []
    /// The track (song) playing now; nil before the first step.
    public var track: TrackInfo?
    /// How the source describes its level right now ("CPU 82%", "4.1 MB/s"), from `MusicSignal.levelLabel`.
    public var levelLabel: String?

    public init() {}

    public func bar(_ settings: SongSettings) -> Int { step / settings.stepsPerBar }
    public func beatInBar(_ settings: SongSettings) -> Int { (step % settings.stepsPerBar) / 4 }
    public func phraseProgress(_ settings: SongSettings) -> Double {
        Double(step % settings.stepsPerPhrase) / Double(settings.stepsPerPhrase)
    }
}

/// What the input has sounded like over the last ten to thirty seconds; it picks and steers the tracks.
///
/// The raw values are part of the song seed (a track hashes `genre/character`), so they never change: the names
/// were born as network input kinds in Wirewatcher, and the same seed must keep writing the same song.
///
/// The raw values are the original traffic words, kept because a track's seed hashes them (so the same seed still
/// writes the same song). JSON uses the case name (`"busy"`) and also accepts the raw value (`"browsing"`).
public enum MusicCharacter: String, Sendable, Hashable, Codable, CaseIterable {
    /// Barely anything moving.
    case idle
    /// Bursty: many short, separate bits of activity (web browsing, a compile fanning out).
    case busy = "browsing"
    /// Steady and roughly balanced both ways, like a video call.
    case steady = "call"
    /// Sustained, heavy and one-way, like a big download.
    case surge = "download"
    /// Faults: resets, failures, errors.
    case chaos

    /// A short word for the legend.
    public var label: String {
        switch self {
        case .idle: "idle"
        case .busy: "busy"
        case .steady: "steady"
        case .surge: "surge"
        case .chaos: "chaos"
        }
    }

    /// The character named by its case name or its raw value.
    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.label == name || $0.rawValue == name }) else {
            return nil
        }
        self = match
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        guard let character = MusicCharacter(name: name) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown music character \(name)")
        }
        self = character
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// The song the conductor is playing: one of a DJ set of generated tracks.
public struct TrackInfo: Sendable, Hashable, Codable {
    /// 1 for the session's first track.
    public var number: Int
    /// A short generated title ("Safari Drift").
    public var name: String
    /// The key, e.g. "F# dorian".
    public var key: String
    public var bpm: Double
    /// The input character the track was written for.
    public var character: MusicCharacter
    /// A few words on the hook ("rising 6-note wobble hook").
    public var hook: String

    public init(number: Int, name: String, key: String, bpm: Double, character: MusicCharacter, hook: String) {
        self.number = number
        self.name = name
        self.key = key
        self.bpm = bpm
        self.character = character
        self.hook = hook
    }
}

/// The bass patch bank's shape, which the conductor needs to pick a track's voice. `NardukMusicDSP.WobblePatch` holds
/// the sounds; `NoteParams.voice` indexes them.
public enum BassPatches {
    /// Base patches; `voice % count` picks one.
    public static let count = 6
    /// Character variants of each base patch; `(voice / count) % variantCount` picks one.
    public static let variantCount = 8
    /// The base patches' names, for the legend.
    public static let names = ["growl", "reese", "square wub", "fm screech", "talker", "riddim"]
}
