import Foundation

// Per-phrase choices for the DropConductor. Since the song-level rewrite most of what a phrase plays belongs to its
// Track (key, hook, progression, patch, groove); a phrase only decides what a phrase should: which statement of the
// hook each two-bar pair plays, the fill on its last bar, and a seed for the ghost notes. Every per-bar choice inside
// it is a pure hash of (plan seed, bar), so the same seed and the same input always write the same song.

/// The fill a drop phrase ends on (its last bar) or touches at the half-phrase (bar 4, last beat only).
enum Fill: Int, Sendable, CaseIterable {
    /// 16th snares rising into the bar line.
    case snareRoll
    /// Kick and bass cut out for the last beat.
    case kickDrop
    /// The bar flips feel: two-step genres go half-time, half-time genres go double-time.
    case halfTime
    /// Snares on a triplet-ish 3-against-4 across the last beats.
    case tripletRoll
    /// The bass chops into octave-jumping 16ths over the last half bar.
    case bassStutter
}

/// One drum variant: kick positions on even and odd bars, the main snares, ghost-snare candidates, open hats.
struct DrumVariant: Sendable, Hashable {
    var kicksA: [Int]
    var kicksB: [Int]
    var snares: [Int]
    var ghosts: [Int]
    /// At most two per bar (the open-hat cap).
    var openHats: [Int]

    init(_ kicksA: [Int], _ kicksB: [Int], snares: [Int], ghosts: [Int] = [], openHats: [Int] = []) {
        self.kicksA = kicksA
        self.kicksB = kicksB
        self.snares = snares
        self.ghosts = ghosts
        self.openHats = openHats
    }
}

struct PhrasePlan: Sendable, Hashable {
    /// The hook statement for each two-bar pair of the phrase.
    var variants: [HookVariant] = [.main, .main, .main, .ending]
    var fill: Fill = .snareRoll
    var midFill: Fill?
    var seed: UInt64 = 0

    func variant(barInPhrase: Int) -> HookVariant { variants[(barInPhrase / 2) % variants.count] }

    /// A stable pseudo-random number for one bar and purpose, independent of call order.
    func bits(_ bar: Int, _ salt: UInt64) -> UInt64 {
        var mix = MusicRNG(
            seed: seed ^ (UInt64(truncatingIfNeeded: bar) &* 0x9E37_79B9_7F4A_7C15) ^ (salt &* 0xD6E8_FEB8_6659_FD93))
        return mix.next()
    }

    func unit(_ bar: Int, _ salt: UInt64) -> Double { Double(bits(bar, salt) >> 11) / Double(1 << 53) }
}

enum PhrasePlanner {
    /// The plan for a new phrase of `track`. Fills alternate between the track's two, except that live chaos stutters
    /// and live idling cuts the kick, so the input still leans on a track it did not write.
    static func plan(track: Track, section: SongSection, phraseInTrack: Int, live: MusicCharacter, roll: UInt64)
        -> PhrasePlan
    {
        var plan = PhrasePlan()
        plan.seed = roll
        plan.variants = track.variants(section: section, live: live)
        switch live {
        case .chaos where track.genre != .chill && track.genre != .lofi: plan.fill = .bassStutter
        case .idle: plan.fill = .kickDrop
        default: plan.fill = track.fills[phraseInTrack % track.fills.count]
        }
        plan.midFill = track.midFill
        return plan
    }
}

/// The material tracks choose from, per genre.
enum Banks {
    // Chord roots per bar as scale degrees: 0 i, 2 III, 3 iv, 4 v, 5 VI, 6 VII.
    static let darkProgressions: [[Int]] = [
        [0, 0, 5, 5, 3, 3, 4, 4], [0, 0, 0, 0, 5, 5, 6, 6], [0, 0, 3, 3, 5, 5, 4, 4], [0, 0, 6, 6, 5, 5, 4, 4],
        [0, 5, 2, 6, 0, 5, 3, 4], [0, 0, 2, 2, 3, 3, 5, 4],
    ]
    static let riddimProgressions: [[Int]] = [
        [0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 5, 5, 4, 4], [0, 0, 0, 0, 1, 1, 0, 0], [0, 0, 0, 0, 6, 6, 5, 5],
    ]
    static let liftProgressions: [[Int]] = [
        [0, 0, 5, 5, 2, 2, 6, 6], [0, 0, 3, 3, 5, 5, 4, 4], [0, 0, 2, 2, 5, 5, 6, 6], [3, 3, 4, 4, 0, 0, 0, 0],
        [0, 0, 6, 6, 5, 5, 6, 6],
    ]

    // Chord roots per bar in a major mode: 0 I, 1 ii, 2 iii, 3 IV, 4 V, 5 vi.
    static let majorProgressions: [[Int]] = [
        [0, 0, 4, 4, 5, 5, 3, 3], [0, 0, 5, 5, 3, 3, 4, 4], [0, 0, 3, 3, 0, 0, 4, 4], [0, 0, 1, 1, 4, 4, 0, 0],
        [0, 4, 5, 3, 0, 4, 3, 4], [3, 3, 0, 0, 4, 4, 5, 5],
    ]

    /// Techno stays on the root for long stretches and moves late.
    static let technoProgressions: [[Int]] = [
        [0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 5, 5, 0, 0], [0, 0, 0, 0, 3, 3, 4, 4], [0, 0, 6, 6, 0, 0, 5, 5],
    ]
    /// Synthwave: the i VI III VII family that carries the 80s sound.
    static let synthwaveProgressions: [[Int]] = [
        [0, 0, 5, 5, 2, 2, 6, 6], [0, 0, 6, 6, 5, 5, 4, 4], [5, 5, 6, 6, 0, 0, 0, 0], [0, 0, 3, 3, 6, 6, 5, 5],
    ]

    static func progressions(_ genre: Genre) -> [[Int]] {
        switch genre {
        case .dubstep, .trap, .drumAndBass: darkProgressions
        case .riddim: riddimProgressions
        case .house, .chill, .ukGarage, .lofi: liftProgressions
        case .techno: technoProgressions
        case .synthwave: synthwaveProgressions
        }
    }

    // MARK: Hook rhythms: two bars as flat (position, length) pairs on a 32-step grid

    static let dubstepHooks: [[Int]] = [
        [0, 6, 6, 2, 8, 4, 12, 4, 16, 6, 22, 2, 24, 8],
        [0, 3, 3, 3, 6, 2, 8, 8, 16, 3, 19, 3, 22, 2, 24, 4, 28, 4],
        [0, 8, 8, 2, 10, 2, 12, 4, 16, 8, 24, 2, 26, 2, 28, 4],
        [0, 4, 6, 2, 8, 6, 14, 2, 16, 4, 22, 2, 24, 3, 27, 3, 30, 2],
        [0, 12, 12, 4, 16, 6, 22, 2, 24, 2, 26, 6],
        [0, 2, 2, 2, 4, 4, 8, 8, 16, 2, 18, 2, 20, 4, 24, 8],
    ]
    static let riddimHooks: [[Int]] = [
        [0, 3, 3, 3, 6, 2, 12, 4, 16, 3, 19, 3, 22, 2, 28, 4],
        [0, 6, 8, 2, 10, 2, 16, 6, 24, 2, 26, 2, 28, 2],
        [0, 4, 4, 4, 12, 2, 16, 4, 20, 4, 28, 2, 30, 2],
        [0, 3, 6, 3, 12, 4, 16, 3, 22, 3, 28, 4],
    ]
    static let dnbHooks: [[Int]] = [
        [0, 6, 6, 4, 10, 6, 16, 10, 26, 6],
        [0, 4, 4, 4, 8, 8, 16, 6, 22, 4, 26, 6],
        [0, 10, 10, 6, 16, 3, 19, 3, 22, 10],
        [0, 6, 6, 2, 8, 8, 16, 8, 24, 4, 28, 4],
    ]
    static let trapHooks: [[Int]] = [
        [0, 2, 3, 2, 6, 2, 8, 2, 10, 2, 12, 4, 16, 2, 19, 2, 22, 2, 24, 4, 28, 4],
        [0, 3, 3, 3, 6, 2, 8, 4, 14, 2, 16, 3, 19, 3, 22, 2, 24, 8],
        [0, 2, 2, 2, 4, 4, 10, 2, 12, 4, 16, 2, 18, 2, 20, 4, 26, 6],
        [0, 4, 6, 2, 8, 2, 10, 6, 16, 4, 22, 2, 24, 2, 26, 6],
    ]
    static let houseHooks: [[Int]] = [
        [0, 2, 3, 2, 6, 2, 10, 2, 13, 2, 16, 2, 19, 2, 22, 4, 28, 2],
        [3, 1, 6, 1, 10, 2, 14, 1, 19, 1, 22, 1, 26, 2, 30, 1],
        [0, 1, 3, 1, 6, 2, 12, 1, 14, 1, 16, 1, 19, 1, 22, 2, 26, 2, 28, 2],
        [2, 2, 6, 2, 10, 2, 14, 2, 18, 2, 22, 2, 26, 2, 29, 2],
    ]
    static let chillHooks: [[Int]] = [
        [0, 6, 6, 2, 8, 8, 18, 4, 22, 2, 24, 8],
        [2, 4, 6, 4, 10, 6, 18, 2, 20, 4, 24, 8],
        [0, 4, 4, 2, 6, 10, 16, 6, 22, 2, 24, 4, 28, 4],
        [0, 3, 3, 5, 8, 8, 16, 3, 19, 5, 24, 8],
    ]

    /// Techno: a short stab or two a bar, mostly off the kick.
    static let technoHooks: [[Int]] = [
        [2, 1, 6, 1, 10, 2, 18, 1, 22, 1, 26, 2],
        [3, 1, 10, 1, 14, 2, 19, 1, 26, 1, 30, 2],
        [0, 1, 6, 1, 8, 1, 14, 2, 22, 1, 24, 1, 30, 2],
        [2, 2, 10, 2, 18, 2, 26, 2, 29, 2],
    ]
    /// UK garage: syncopated chord chops that skip over the 2-step kick.
    static let ukgHooks: [[Int]] = [
        [0, 3, 3, 2, 7, 3, 10, 2, 16, 3, 19, 2, 23, 3, 26, 4],
        [2, 2, 5, 3, 10, 4, 16, 2, 18, 3, 22, 2, 26, 4],
        [0, 2, 3, 3, 6, 2, 10, 3, 14, 2, 16, 3, 20, 3, 26, 2, 30, 2],
        [0, 4, 6, 3, 11, 3, 16, 2, 19, 3, 23, 2, 27, 4],
    ]
    /// Synthwave: a long-note lead that climbs and holds over the driving bass.
    static let synthwaveHooks: [[Int]] = [
        [0, 6, 8, 2, 10, 2, 12, 4, 16, 6, 24, 2, 26, 2, 28, 4],
        [0, 8, 8, 4, 12, 4, 16, 8, 24, 4, 28, 4],
        [0, 3, 4, 4, 8, 8, 16, 3, 20, 4, 24, 8],
        [0, 2, 2, 2, 4, 4, 8, 8, 16, 2, 18, 2, 20, 4, 24, 8],
    ]
    /// Lo-fi: lazy, long, late; the notes sit behind the beat.
    static let lofiHooks: [[Int]] = [
        [1, 5, 8, 7, 17, 3, 22, 2, 25, 7],
        [0, 6, 7, 3, 12, 4, 18, 6, 25, 6],
        [2, 4, 7, 5, 14, 2, 18, 4, 23, 8],
        [0, 3, 4, 3, 10, 6, 17, 4, 24, 8],
    ]

    static func hookRhythms(_ genre: Genre) -> [[Int]] {
        switch genre {
        case .dubstep: dubstepHooks
        case .riddim: riddimHooks
        case .drumAndBass: dnbHooks
        case .trap: trapHooks
        case .house: houseHooks
        case .chill: chillHooks
        case .techno: technoHooks
        case .ukGarage: ukgHooks
        case .synthwave: synthwaveHooks
        case .lofi: lofiHooks
        }
    }

    // MARK: Drums (drop sections)

    static let dubstepDrums: [DrumVariant] = [
        DrumVariant([0], [0, 10], snares: [8], ghosts: [6, 14, 15]),
        DrumVariant([0, 3], [0, 10, 14], snares: [8], ghosts: [11, 15], openHats: [12]),
        DrumVariant([0, 6], [0, 11], snares: [8], ghosts: [3, 14]),
        DrumVariant([0, 10], [0, 7, 10], snares: [8], ghosts: [6, 13, 15], openHats: [14]),
        DrumVariant([0, 2], [0, 10, 12], snares: [8], ghosts: [5, 11]),
    ]
    static let riddimDrums: [DrumVariant] = [
        DrumVariant([0], [0], snares: [8], ghosts: [15]),
        DrumVariant([0], [0, 6], snares: [8], ghosts: [14]),
        DrumVariant([0, 14], [0], snares: [8], ghosts: [11]),
    ]
    /// Two-step breakbeats: kicks on 1 and the "and" of 3, snares on 2 and 4, ghosts all over.
    static let dnbDrums: [DrumVariant] = [
        DrumVariant([0, 10], [0, 10], snares: [4, 12], ghosts: [7, 15, 9]),
        DrumVariant([0, 10], [0, 6, 10], snares: [4, 12], ghosts: [9, 14, 2], openHats: [2]),
        DrumVariant([0, 2, 10], [0, 10, 11], snares: [4, 12], ghosts: [7, 9, 15]),
        DrumVariant([0, 10], [0, 3, 10], snares: [4, 12], ghosts: [6, 14, 7], openHats: [8]),
    ]
    static let trapDrums: [DrumVariant] = [
        DrumVariant([0, 7], [0, 11], snares: [8], ghosts: [15]),
        DrumVariant([0, 3, 11], [0, 7], snares: [8], ghosts: [14]),
        DrumVariant([0, 10], [0, 6, 14], snares: [8], ghosts: [12]),
        DrumVariant([0, 14], [0, 3, 10], snares: [8], ghosts: [11]),
    ]
    static let houseDrums: [DrumVariant] = [
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12], snares: [4, 12], ghosts: [15], openHats: [6, 14]),
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12], snares: [4, 12], ghosts: [7, 15], openHats: [2, 10]),
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12, 14], snares: [4, 12], ghosts: [11], openHats: [6, 14]),
    ]
    static let chillDrums: [DrumVariant] = [
        DrumVariant([0], [0, 10], snares: [8], ghosts: [14, 3]),
        DrumVariant([0, 7], [0], snares: [8], ghosts: [3, 15]),
        DrumVariant([0, 11], [0, 6], snares: [8], ghosts: [13, 5]),
    ]

    /// Techno: four on the floor, a clap on 2 and 4, open hats on every off-beat.
    static let technoDrums: [DrumVariant] = [
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12], snares: [4, 12], ghosts: [15], openHats: [2, 6, 10, 14]),
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12], snares: [4, 12], ghosts: [7], openHats: [2, 10]),
        DrumVariant([0, 4, 8, 12], [0, 4, 8, 12, 15], snares: [4, 12], ghosts: [6, 14], openHats: [6, 14]),
    ]
    /// UK garage 2-step: the kick skips beat 3, the snare is on 2 and 4, ghost snares shuffle between.
    static let ukgDrums: [DrumVariant] = [
        DrumVariant([0, 10], [0, 10], snares: [4, 12], ghosts: [7, 9, 15], openHats: [2, 14]),
        DrumVariant([0, 10], [0, 6, 10], snares: [4, 12], ghosts: [3, 9, 14], openHats: [6]),
        DrumVariant([0, 10], [0, 10, 11], snares: [4, 12], ghosts: [7, 15, 5], openHats: [14]),
        DrumVariant([0, 7, 10], [0, 10], snares: [4, 12], ghosts: [9, 15], openHats: [2, 10]),
    ]
    /// Synthwave: a big gated backbeat, the kick on 1 and 3.
    static let synthwaveDrums: [DrumVariant] = [
        DrumVariant([0, 8], [0, 8], snares: [4, 12], ghosts: [], openHats: [14]),
        DrumVariant([0, 8], [0, 8, 10], snares: [4, 12], ghosts: [15], openHats: [6, 14]),
        DrumVariant([0, 6, 8], [0, 8], snares: [4, 12], ghosts: [], openHats: [14]),
    ]
    /// Lo-fi hip hop boom-bap: a lazy kick, the snare on 2 and 4, ghosts late.
    static let lofiDrums: [DrumVariant] = [
        DrumVariant([0, 10], [0, 7, 10], snares: [4, 12], ghosts: [14, 15], openHats: []),
        DrumVariant([0, 7], [0, 10], snares: [4, 12], ghosts: [3, 15], openHats: []),
        DrumVariant([0, 11], [0, 6, 10], snares: [4, 12], ghosts: [13, 7], openHats: []),
    ]

    static func drums(_ genre: Genre) -> [DrumVariant] {
        switch genre {
        case .dubstep: dubstepDrums
        case .riddim: riddimDrums
        case .drumAndBass: dnbDrums
        case .trap: trapDrums
        case .house: houseDrums
        case .chill: chillDrums
        case .techno: technoDrums
        case .ukGarage: ukgDrums
        case .synthwave: synthwaveDrums
        case .lofi: lofiDrums
        }
    }

    // MARK: Wobble-rate ladders

    static func rateLadder(_ genre: Genre) -> [WobbleRate] {
        switch genre {
        case .dubstep: [.half, .quarter, .eighth, .eighthTriplet, .sixteenth, .sixteenthTriplet]
        case .riddim: [.eighthTriplet, .sixteenthTriplet]
        case .drumAndBass: [.quarter, .eighth, .sixteenth]
        case .trap: [.quarter]
        case .house: [.quarter, .eighth, .sixteenth]
        case .chill: [.half, .quarter]
        case .techno: [.eighth, .sixteenth]
        case .ukGarage: [.quarter, .eighth]
        case .synthwave: [.quarter]
        case .lofi: [.half, .quarter]
        }
    }
}
