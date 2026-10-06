import Foundation

// Harmony vocabulary: the modes a song can be written in, how a chord is voiced, how it is played (sustained, struck
// in stabs, strummed, arpeggiated) and the genre families a song's shape can follow. Everything here is a pure value
// or a pure function, so the conductor, tests and the instrument lanes (a strummed guitar wants a voiced chord and
// staggered onsets) share one source of truth. Nothing here is on by default: a `SongSettings` that sets none of it
// writes exactly the song it always wrote.

// MARK: - Mode

/// The scale a song can be written in. `SongSettings.mode` nil lets each track pick its own from the genre and the
/// input (the minor family); setting it pins every track to this mode.
public enum HarmonyMode: String, Sendable, Hashable, Codable, CaseIterable {
    case minor, dorian, phrygian, harmonicMinor
    case major, lydian, mixolydian

    /// Semitones above the tonic of each of the seven degrees.
    public var scale: [Int] { internalMode.scale }

    /// "minor", "major", "dorian", ...: how the key is named in `TrackInfo.key`.
    public var name: String { internalMode.name }

    /// Whether the tonic triad has a major third (major, lydian, mixolydian).
    public var isMajorQuality: Bool { scale[2] == 4 }

    /// Semitones above the tonic for a scale degree; any integer, octaves carried (7 is the octave, -1 the 7th below).
    public func semitones(_ degree: Int) -> Int { internalMode.semitones(degree) }

    var internalMode: Mode {
        switch self {
        case .minor: .aeolian
        case .dorian: .dorian
        case .phrygian: .phrygian
        case .harmonicMinor: .harmonicMinor
        case .major: .ionian
        case .lydian: .lydian
        case .mixolydian: .mixolydian
        }
    }
}

// MARK: - Voicing

/// How the notes of a chord are spread over the keyboard or the strings.
public enum ChordVoicing: String, Sendable, Hashable, Codable, CaseIterable {
    /// Stacked thirds from the root: the tightest position.
    case close
    /// The third lifted an octave: root, fifth, third.
    case open
    /// The second note from the top dropped an octave: the guitar-friendly spread.
    case drop2
    /// Open position with the root doubled an octave below: a wide pad.
    case spread
    /// Root, third and seventh: the guide tones (always includes the seventh).
    case shell
    /// Root, fifth and the octave: no third, so it works in any mode.
    case power
}

/// Chords as MIDI pitches.
public enum Harmony {
    /// The pitches of the chord built on scale `degree` of `mode`, low to high.
    ///
    /// `tonic` is the MIDI pitch of the key's tonic in the register the chord is built from (the root of the chord
    /// sits at or just above `tonic` plus its degree), the same convention as the conductor's own pitches. `seventh`
    /// adds the chord's seventh (always present in `.shell`).
    public static func chordPitches(
        mode: HarmonyMode, tonic: Int, degree: Int, voicing: ChordVoicing = .close, seventh: Bool = false
    ) -> [Int] {
        pitches(mode: mode.internalMode, tonic: tonic, degree: degree, voicing: voicing, seventh: seventh)
    }

    static func pitches(mode: Mode, tonic: Int, degree: Int, voicing: ChordVoicing, seventh: Bool) -> [Int] {
        func tone(_ index: Int) -> Int { tonic + mode.semitones(degree + 2 * index) }
        let hasSeventh = seventh || voicing == .shell
        let close = (hasSeventh ? [0, 1, 2, 3] : [0, 1, 2]).map(tone)
        switch voicing {
        case .close:
            return close
        case .open:
            return opened(close)
        case .drop2:
            var voiced = close
            voiced[voiced.count - 2] -= 12
            return voiced.sorted()
        case .spread:
            return [close[0] - 12] + opened(close)
        case .shell:
            return [close[0], close[1], close[3]]
        case .power:
            return [close[0], close[2], close[0] + 12]
        }
    }

    /// The second note an octave up, re-sorted: root, fifth, third for a triad.
    private static func opened(_ close: [Int]) -> [Int] {
        var voiced = close
        voiced[1] += 12
        return voiced.sorted()
    }
}

// MARK: - Comping

/// How a strummed or struck chord's notes are ordered in time.
public enum StrumDirection: String, Sendable, Hashable, Codable, CaseIterable {
    /// All notes at once.
    case block
    /// Low string to high, each a little later than the last.
    case down
    /// High string to low.
    case up

    /// The longest total spread, in steps: `NoteParams.delay` tops out at half a step.
    public static let maxSpread = 0.5
    /// The delay between neighbouring strings, in steps (13 ms at 140 BPM).
    public static let stagger = 0.1

    /// Onset delay in steps for each note of a chord of `count` notes, in the chord's low-to-high order. Never
    /// beyond `maxSpread`, so six strings still fit.
    public func delays(count: Int) -> [Double] {
        guard count > 1, self != .block else { return Array(repeating: 0, count: max(0, count)) }
        let gap = min(Self.stagger, Self.maxSpread / Double(count - 1))
        return (0..<count).map { index in
            gap * Double(self == .down ? index : count - 1 - index)
        }
    }
}

/// One stroke of a comping pattern.
public struct CompHit: Sendable, Hashable {
    /// Position on a 16-step bar grid.
    public var pos: Int
    public var direction: StrumDirection
    /// 0 ... 1 multiplier on the layer's velocity.
    public var velocity: Double
    /// Length in 16-grid steps (the conductor scales it to the bar size).
    public var length: Int
    /// For an arpeggio, the chord tone this hit plays (wrapping around the chord); nil plays the whole chord.
    public var tone: Int?

    public init(
        pos: Int, direction: StrumDirection = .block, velocity: Double = 1, length: Int = 2, tone: Int? = nil
    ) {
        self.pos = pos
        self.direction = direction
        self.velocity = velocity
        self.length = length
        self.tone = tone
    }

    /// The notes this hit plays on a chord given low to high, as pitch, velocity multiplier and delay in steps.
    public func notes(on chord: [Int]) -> [CompNote] {
        guard !chord.isEmpty else { return [] }
        if let tone {
            return [
                CompNote(pitch: chord[((tone % chord.count) + chord.count) % chord.count], velocity: velocity, delay: 0)
            ]
        }
        let delays = direction.delays(count: chord.count)
        return chord.enumerated().map { index, pitch in
            // A strum softens a little along its length, the way a pick does.
            let fade = direction == .block ? 1 : 1 - 0.06 * Double(direction == .down ? index : chord.count - 1 - index)
            return CompNote(pitch: pitch, velocity: velocity * fade, delay: delays[index])
        }
    }
}

/// A note a comping hit plays.
public struct CompNote: Sendable, Hashable {
    public var pitch: Int
    /// 0 ... 1 multiplier on the layer's velocity.
    public var velocity: Double
    /// Steps the note sounds late, 0 ... 0.5.
    public var delay: Double

    public init(pitch: Int, velocity: Double, delay: Double) {
        self.pitch = pitch
        self.velocity = velocity
        self.delay = delay
    }
}

/// How the chords are played: a repeating pattern of strokes over the bar's chord.
public enum CompingPattern: String, Sendable, Hashable, Codable, CaseIterable {
    /// The chord held for two bars, no rhythm.
    case sustain
    /// Short block chords on the off-beats (house, funk).
    case stabs
    /// One down-strum on each half bar.
    case strum
    /// The folk strum: down, down, up, up, down, up.
    case folk
    /// The chord's notes one at a time, a 16th apart, up and back.
    case arpeggio

    /// A short word for the legend.
    public var label: String {
        switch self {
        case .sustain: "held chords"
        case .stabs: "chord stabs"
        case .strum: "strummed chords"
        case .folk: "folk strum"
        case .arpeggio: "arpeggio"
        }
    }

    /// Bars the pattern spans before repeating; `hits(...)` reads the bar's position inside it.
    public var bars: Int { self == .sustain ? 2 : 1 }

    /// The strokes of one pass of the pattern.
    public var strokes: [CompHit] {
        switch self {
        case .sustain:
            [CompHit(pos: 0, velocity: 0.7, length: 32)]
        case .stabs:
            [2, 6, 10, 14].map { CompHit(pos: $0, velocity: $0 == 6 ? 1 : 0.8, length: 2) }
        case .strum:
            [CompHit(pos: 0, direction: .down, length: 8), CompHit(pos: 8, direction: .down, velocity: 0.8, length: 8)]
        case .folk:
            [
                CompHit(pos: 0, direction: .down, length: 4),
                CompHit(pos: 4, direction: .down, velocity: 0.85, length: 2),
                CompHit(pos: 6, direction: .up, velocity: 0.6, length: 2),
                CompHit(pos: 10, direction: .up, velocity: 0.6, length: 2),
                CompHit(pos: 12, direction: .down, velocity: 0.85, length: 2),
                CompHit(pos: 14, direction: .up, velocity: 0.6, length: 2),
            ]
        case .arpeggio:
            [0, 1, 2, 3, 2, 1, 2, 3].enumerated().map {
                CompHit(pos: $0.offset * 2, velocity: $0.offset % 4 == 0 ? 1 : 0.7, length: 3, tone: $0.element)
            }
        }
    }

    /// The strokes that start at `pos` of a bar (16-step grid) of the phrase.
    public func hits(pos: Int, barInPhrase: Int) -> [CompHit] {
        guard barInPhrase % bars == 0 else { return [] }
        return strokes.filter { $0.pos == pos }
    }
}

// MARK: - Families

/// The kind of music a genre belongs to. A family may change a song's shape, not only its tempo and patterns. The six
/// existing genres are all `electronic`; `band` and `ambient` are defined here so settings can already name them and
/// the lanes that write those genres have a place to hang their shape.
public enum GenreFamily: String, Sendable, Hashable, Codable, CaseIterable {
    case electronic, band, ambient

    /// The genres written for this family today.
    public var genres: [Genre] {
        switch self {
        case .electronic: Genre.allCases
        case .band, .ambient: []
        }
    }

    /// The song-shape defaults the family contributes when `SongSettings` leaves them unset.
    public var shape: FamilyShape {
        switch self {
        case .electronic: FamilyShape()
        case .band: FamilyShape(voicing: .drop2, comping: .folk)
        case .ambient: FamilyShape(voicing: .spread, comping: .sustain)
        }
    }
}

extension Genre {
    /// The family the genre belongs to.
    public var family: GenreFamily { .electronic }
}

/// What a family contributes to a song's shape. Nil means "as the genre's own arrangement does it", which for
/// `electronic` is every field: the existing arrangements are untouched.
public struct FamilyShape: Sendable, Hashable {
    /// How chords are voiced (nil: the arrangement's own close stacks).
    public var voicing: ChordVoicing?
    /// A chord layer played over the arrangement (nil: none).
    public var comping: CompingPattern?

    public init(voicing: ChordVoicing? = nil, comping: CompingPattern? = nil) {
        self.voicing = voicing
        self.comping = comping
    }
}
