import Foundation
import NardukMusicCore

// Real-time-safe DSP building blocks for the Network Dubstep synth (#45).
// Everything here is a plain value type with trivially copyable state: no
// allocation, no locks and no reference counting on the render path.

public enum DSP {
    public static let twoPi: Float = 2 * .pi
    /// -1 dBFS, the master ceiling the limiter never exceeds.
    public static let ceiling: Float = 0.891_250_9
    /// Added to recursive filter states so a decaying tail never drops into denormals.
    public static let antiDenormal: Float = 1e-20

    @inline(__always) public static func midiToHz(_ note: Float) -> Float {
        440 * exp2f((note - 69) / 12)
    }

    /// A Padé approximation of tanh, exact at ±3 and hard-limited beyond: a cheap, smooth soft clip.
    @inline(__always) public static func softClip(_ x: Float) -> Float {
        let c = min(max(x, -3), 3)
        return c * (27 + c * c) / (27 + 9 * c * c)
    }

    /// PolyBLEP residual for a discontinuity at phase 0 (t and dt in cycles).
    @inline(__always) public static func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    /// Band-limited sawtooth, -1 ... 1.
    @inline(__always) public static func saw(_ phase: Float, _ dt: Float) -> Float {
        2 * phase - 1 - polyBLEP(phase, dt)
    }

    /// Band-limited square, -1 ... 1.
    @inline(__always) public static func square(_ phase: Float, _ dt: Float) -> Float {
        var shifted = phase + 0.5
        if shifted >= 1 { shifted -= 1 }
        return (phase < 0.5 ? 1 : -1) + polyBLEP(phase, dt) - polyBLEP(shifted, dt)
    }

    /// Per-sample multiplier for an exponential decay with time constant `seconds`.
    @inline(__always) public static func decay(seconds: Float, sampleRate: Float) -> Float {
        expf(-1 / max(seconds * sampleRate, 1))
    }

    @inline(__always) public static func decibels(_ amplitude: Float) -> Float {
        amplitude > 1e-6 ? 20 * log10f(amplitude) : -120
    }

    /// Equal-power pan gains for -1 (left) ... 1 (right).
    @inline(__always) public static func pan(_ position: Float) -> (left: Float, right: Float) {
        let p = (min(max(position, -1), 1) + 1) * 0.25 * .pi
        return (cosf(p), sinf(p))
    }

    /// Wraps a phase accumulator into 0 ..< 1.
    @inline(__always) public static func wrap(_ phase: Float) -> Float {
        phase >= 1 ? phase - floorf(phase) : (phase < 0 ? phase - floorf(phase) : phase)
    }
}

/// xorshift32 white noise, -1 ... 1.
public struct NoiseSource: Sendable, Hashable {
    public var state: UInt32

    public init(seed: UInt32) {
        state = seed == 0 ? 0x1234_5678 : seed
    }

    @inline(__always) public mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(Int32(bitPattern: state)) * (1 / 2_147_483_648)
    }
}

/// One-pole lowpass/highpass (for DC blocking, click shaping and parameter smoothing).
public struct OnePole: Sendable, Hashable {
    public var z: Float = 0
    public var coefficient: Float = 0

    public init() {}

    public init(cutoff: Float, sampleRate: Float) {
        setCutoff(cutoff, sampleRate: sampleRate)
    }

    public mutating func setCutoff(_ cutoff: Float, sampleRate: Float) {
        coefficient = expf(-DSP.twoPi * max(cutoff, 1) / sampleRate)
    }

    @inline(__always) public mutating func lowpass(_ x: Float) -> Float {
        z = x + coefficient * (z - x) + DSP.antiDenormal
        return z
    }

    @inline(__always) public mutating func highpass(_ x: Float) -> Float {
        x - lowpass(x)
    }
}

/// Topology-preserving-transform (zero-delay-feedback) state-variable filter
/// (Zavalishin / Simper). Unconditionally stable for any cutoff below Nyquist
/// and any damping above zero, so it is safe to modulate every sample.
public struct SVF: Sendable, Hashable {
    public var ic1: Float = 0
    public var ic2: Float = 0
    private var k: Float = 2
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0

    /// The highest usable resonance; damping never reaches zero, so the filter never self-oscillates unbounded.
    public static let maxResonance: Float = 0.985

    public init() {}

    public init(cutoff: Float, resonance: Float, sampleRate: Float) {
        set(cutoff: cutoff, resonance: resonance, sampleRate: sampleRate)
    }

    /// cutoff in Hz, resonance 0 ... 1.
    @inline(__always) public mutating func set(cutoff: Float, resonance: Float, sampleRate: Float) {
        let fc = min(max(cutoff, 10), sampleRate * 0.45)
        let g = tanf(.pi * fc / sampleRate)
        k = 2 - 2 * min(max(resonance, 0), SVF.maxResonance)
        a1 = 1 / (1 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
    }

    @inline(__always) public mutating func process(_ v0: Float) -> (low: Float, band: Float, high: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1 + DSP.antiDenormal
        ic2 = 2 * v2 - ic2 + DSP.antiDenormal
        return (v2, v1, v0 - k * v1 - v2)
    }

    public mutating func reset() {
        ic1 = 0
        ic2 = 0
    }
}

/// Exponential attack/decay envelope used by the percussive voices.
public struct DecayEnvelope: Sendable, Hashable {
    public var value: Float = 0
    public var multiplier: Float

    public init(seconds: Float, sampleRate: Float) {
        multiplier = DSP.decay(seconds: seconds, sampleRate: sampleRate)
    }

    public mutating func trigger(_ level: Float = 1) { value = level }

    @inline(__always) public mutating func next() -> Float {
        let v = value
        value *= multiplier
        return v
    }

    public var isSilent: Bool { value < 1e-4 }
}
