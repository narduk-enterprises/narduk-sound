import Foundation
import NardukMusicCore

/// A track's `TimbreMacro` turned into the multipliers a voice applies when a note starts (narduk-sound#33). Decoded
/// once per note on the render thread from the event's packed integer: plain arithmetic, no allocation. `.neutral`
/// leaves every voice exactly as it was, so a note without a macro renders bit for bit as before.
public struct TimbrePatch: Sendable, Hashable, BitwiseCopyable {
    /// False for `.neutral`: the voice skips every adjustment.
    public private(set) var isActive = false
    /// Filter cutoff multiplier: the macro's tone and the note's velocity (a soft note darker, a hard one brighter).
    public private(set) var cutoff: Float = 1
    /// The macro's tone alone (about ±0.7 octave at full reach), for a voice that already brightens with velocity.
    public private(set) var tone: Float = 1
    /// Attack time multiplier: the macro's (0.5 ... 2 at full reach), quicker for a hard note and softer for a gentle
    /// one, so velocity shapes the onset's spectrum as well as its level.
    public private(set) var attack: Float = 1
    /// Decay and release time multiplier (about 0.66 ... 1.5 at full reach).
    public private(set) var decay: Float = 1
    /// Detune spread multiplier (0.5 ... 2 at full reach).
    public private(set) var detune: Float = 1
    /// Stereo width multiplier (0.65 ... 1.35 at full reach).
    public private(set) var width: Float = 1
    /// Added to a 0 ... 1 drive (±0.2 at full reach).
    public private(set) var drive: Float = 0
    /// Pitch multiplier of one drum hit (the round-robin's few cents).
    public private(set) var pitch: Float = 1
    /// Decay multiplier of one drum hit (the round-robin's few percent).
    public private(set) var hitDecay: Float = 1
    /// The seed a drum hit's noise restarts from; 0 keeps the voice's running noise.
    public private(set) var noiseSeed: UInt32 = 0
    private var variationSeed: UInt32 = 0

    public static let neutral = TimbrePatch()

    public init() {}

    /// The patch for a note: `packed` is the event's `timbre` (0 is `.neutral`), `velocity` its 0 ... 1 velocity.
    public init(packed: Int64, velocity: Float) {
        guard let macro = TimbreMacro(packed: Int(truncatingIfNeeded: packed)) else { return }
        isActive = true
        let force = min(max(velocity, 0), 1) - 0.75
        tone = exp2f(Float(macro.cutoff) * 0.7)
        cutoff = tone * exp2f(force * 0.6)
        attack = exp2f(Float(macro.attack) - force * 0.8)
        decay = exp2f(Float(macro.decay) * 0.6)
        detune = exp2f(Float(macro.detune))
        width = 1 + Float(macro.width) * 0.35
        drive = Float(macro.drive) * 0.2
        variationSeed = UInt32(macro.variationSeed) &* 0x9E37_79B9
    }

    /// Round-robin micro-variation for the `round`th drum hit of a render: pitch within ±4 cents, decay within ±8 %,
    /// and a fresh noise seed, so repeated kicks, snares and hats are never bit-identical. A pure function of the
    /// round and the track's seed, so a render repeats exactly. No effect on `.neutral`.
    public mutating func vary(round: UInt32) {
        guard isActive else { return }
        var h = (round &+ variationSeed) &* 0x85EB_CA6B
        h ^= h >> 13
        h &*= 0xC2B2_AE35
        h ^= h >> 16
        func unit(_ shift: UInt32) -> Float { Float((h >> shift) & 0xFF) / 255 * 2 - 1 }
        pitch = exp2f(unit(0) * 4 / 1_200)
        hitDecay = 1 + unit(8) * 0.08
        noiseSeed = h | 1
    }

    /// Drums take half the macro's reach (a square root) on decay and cutoff, so the groove keeps its shape, and
    /// the hit's own round-robin on top.
    public var drumDecay: Float { isActive ? decay.squareRoot() * hitDecay : 1 }
    public var drumCutoff: Float { isActive ? cutoff.squareRoot() : 1 }

    /// A per-sample decay coefficient (`DSP.decay`) for a time `scale` times as long.
    @inline(__always) public static func scaled(_ coefficient: Float, by scale: Float) -> Float {
        scale == 1 ? coefficient : powf(coefficient, 1 / scale)
    }
}
