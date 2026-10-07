import Foundation

/// One track's timbre (narduk-sound#33): six bipolar offsets the synth voices apply when a note starts, so two tracks
/// of one genre with the same patches still sound different. Every value is -1 ... 1 and 0 leaves a voice exactly as
/// it was; `DropSynthCore` maps each to its own physical span (an octave or so of cutoff, a doubling of attack time).
///
/// A note carries the macro packed into `NoteParams.timbre`. A note without one plays the voices' standard sound, bit
/// for bit, with no round-robin and no velocity brightness: those belong to a track's timbre.
public struct TimbreMacro: Sendable, Hashable, Codable {
    /// Spread of the detuned oscillators: wider (positive) or tighter.
    public var detune: Double
    /// Filter cutoff: brighter (positive) or darker.
    public var cutoff: Double
    /// Attack time: slower (positive) or snappier.
    public var attack: Double
    /// Decay and release time: longer (positive) or shorter.
    public var decay: Double
    /// Stereo width: wider (positive) or narrower.
    public var width: Double
    /// Saturation: more (positive) or less.
    public var drive: Double
    /// Seeds the drums' round-robin, so two tracks with the same macro still vary their hits differently.
    public var variationSeed: UInt8

    public init(
        detune: Double = 0, cutoff: Double = 0, attack: Double = 0, decay: Double = 0, width: Double = 0,
        drive: Double = 0, variationSeed: UInt8 = 0
    ) {
        self.detune = Self.quantized(detune)
        self.cutoff = Self.quantized(cutoff)
        self.attack = Self.quantized(attack)
        self.decay = Self.quantized(decay)
        self.width = Self.quantized(width)
        self.drive = Self.quantized(drive)
        self.variationSeed = variationSeed
    }

    /// The values in packing order.
    public var values: [Double] { [detune, cutoff, attack, decay, width, drive] }

    // MARK: Packing

    /// Bit 56 marks a packed macro, so an all-zero one is still a track's timbre (and still varies its drums).
    static let presentBit = 1 << 56

    /// The macro as one integer for `NoteParams.timbre`: six signed bytes, the variation seed, and a presence bit.
    public var packed: Int {
        var bits = Self.presentBit | Int(variationSeed) << 48
        for (index, value) in values.enumerated() {
            bits |= Int(UInt8(bitPattern: Int8(Self.byte(value)))) << (8 * index)
        }
        return bits
    }

    /// Decodes `packed`; nil when it carries no macro (0, or a value without the presence bit).
    public init?(packed: Int) {
        guard packed & Self.presentBit != 0 else { return nil }
        func value(_ index: Int) -> Double {
            Double(Int8(bitPattern: UInt8(truncatingIfNeeded: packed >> (8 * index)))) / 127
        }
        self.init(
            detune: value(0), cutoff: value(1), attack: value(2), decay: value(3), width: value(4), drive: value(5),
            variationSeed: UInt8(truncatingIfNeeded: packed >> 48))
    }

    private static func byte(_ value: Double) -> Int {
        Int((min(max(value.isFinite ? value : 0, -1), 1) * 127).rounded())
    }

    /// A value as it survives packing, so a macro equals its own round trip.
    private static func quantized(_ value: Double) -> Double { Double(byte(value)) / 127 }

    // MARK: Drawing

    /// How far a genre's macro may reach from its standard sound, 0 ... 1. The gentle genres keep a narrow range:
    /// their softness is the genre, and a hard edge would break it.
    public static func range(_ genre: Genre) -> Double {
        switch genre {
        case .tropicalHouse, .lofi, .chill: 0.3
        case .house, .ukGarage, .synthwave, .folk, .funk: 0.6
        case .dubstep, .riddim, .drumAndBass, .trap, .techno, .rock: 0.85
        }
    }

    /// The characters a genre's tracks are drawn from: two or three each, so a track sounds like one designed patch
    /// rather than six knobs turned at random.
    public static func characters(_ genre: Genre) -> [TimbreCharacter] {
        switch genre {
        case .tropicalHouse, .lofi, .chill, .house, .ukGarage, .synthwave, .folk, .funk: [.warm, .tight, .airy]
        case .dubstep, .riddim, .drumAndBass, .trap, .techno, .rock: [.tight, .gritty, .warm]
        }
    }

    /// Share of each axis that is the character's; the rest is a small jitter, so two tracks of one character still
    /// differ a little.
    static let characterShare = 0.8

    /// Each axis's bounds for a genre at full variety: the hull of its characters, plus the jitter.
    public static func bounds(_ genre: Genre) -> [ClosedRange<Double>] {
        let reach = range(genre)
        let vectors = characters(genre).map(\.vector)
        return (0..<6).map { axis in
            let values = vectors.map { $0[axis] * characterShare }
            let jitter = 1 - characterShare
            return (max((values.min() ?? 0) - jitter, -1) * reach)...(min((values.max() ?? 0) + jitter, 1) * reach)
        }
    }

    /// A track's macro: one of the genre's characters (a different one from `previous` when there is a choice), its
    /// axes scaled by the genre's range and `variety`, with a little jitter. From a stream of its own, so no other
    /// draw of the track moves.
    public static func draw(
        genre: Genre, seed: UInt64, variety: Double, previous: TimbreCharacter? = nil
    ) -> (TimbreCharacter, TimbreMacro) {
        var rng = MusicRNG(seed: seed ^ StableHash.fnv1a("timbre-macro"))
        let choices = characters(genre)
        var pick = Int(rng.next() % UInt64(choices.count))
        if choices[pick] == previous, choices.count > 1 {
            pick = (pick + 1 + Int(rng.next() % UInt64(choices.count - 1))) % choices.count
        }
        let character = choices[pick]
        let reach = range(genre) * min(max(variety, 0), 1)
        let v = character.vector.map { value in
            let jitter = (rng.unit() * 2 - 1) * (1 - characterShare)
            return min(max(value * characterShare + jitter, -1), 1) * reach
        }
        let macro = TimbreMacro(
            detune: v[0], cutoff: v[1], attack: v[2], decay: v[3], width: v[4], drive: v[5],
            variationSeed: UInt8(truncatingIfNeeded: rng.next()))
        return (character, macro)
    }
}

/// A designed timbre: its axes move together (a slow attack with a dark tone and a long decay), as a sound designer
/// would set a patch, rather than each knob on its own.
public enum TimbreCharacter: String, Sendable, Hashable, Codable, CaseIterable {
    /// Dark, slow to open, long and soft: a rounded, mellow take.
    case warm
    /// Bright, snappy, short and narrow: a punchy, dry take.
    case tight
    /// Wide detune and stereo, driven, quick: a rough, aggressive take.
    case gritty
    /// Bright but slow, long, wide and clean: an open, spacious take.
    case airy

    /// The axes in `TimbreMacro.values` order: detune, cutoff, attack, decay, width, drive.
    public var vector: [Double] {
        switch self {
        case .warm: [0.3, -0.8, 0.7, 0.6, 0.3, -0.5]
        case .tight: [-0.6, 0.6, -0.8, -0.7, -0.5, 0.3]
        case .gritty: [0.8, 0.3, -0.4, -0.3, 0.6, 0.9]
        case .airy: [0.5, 0.5, 0.4, 0.8, 0.9, -0.7]
        }
    }
}
