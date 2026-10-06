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

    public init(
        pitch: Int? = nil, lengthSteps: Int = 1, wobbleRate: WobbleRate? = nil, formant: Double? = nil,
        drive: Double? = nil, voice: Int? = nil, pan: Double = 0, glide: Double? = nil, delay: Double? = nil
    ) {
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

    public init(
        bpm: Double = 140, genre: Genre = .dubstep, keyRoot: Int = 65, stepsPerBar: Int = 16, barsPerPhrase: Int = 8,
        seed: UInt64 = 0x5EED, family: GenreFamily = .electronic, mode: HarmonyMode? = nil,
        voicing: ChordVoicing? = nil, comping: CompingPattern? = nil
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
            comping: try container.decodeIfPresent(CompingPattern.self, forKey: .comping))
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
