import Foundation
import NardukMusicCore

/// Per-sample-rate constants shared by every voice, computed once per synth.
public struct SynthCoefficients: Sendable, Hashable {
    public let sampleRate: Float
    public let invSampleRate: Float
    /// Linear fade per sample for a stolen voice (4 ms), so retriggers never click.
    public let stealFadeStep: Float
    /// Linear attack per sample for gated voices (3 ms).
    public let attackStep: Float
    /// Release multiplier for gated voices (~18 ms).
    public let release: Float
    /// Pitch glide multiplier (~35 ms).
    public let glide: Float
    /// Bus gain smoothing (~10 ms).
    public let smoothing: Float

    let kickPitchFast: Float
    let kickPitchSlow: Float
    let kickClick: Float
    let kickDecay: Float
    let kickHold: Int
    let kickTailStart: Int
    let kickTail: Float
    let kickClickHighpass: Float

    let snarePitch: Float
    let snareBody: Float
    let snareNoise: Float
    let snareSnap: Float

    let hatClosed: Float
    let hatOpen: Float

    let sidechainAttack: Float
    let sidechainRelease: Float

    public init(sampleRate: Double) {
        let sr = Float(sampleRate)
        self.sampleRate = sr
        invSampleRate = 1 / sr
        stealFadeStep = 1 / (0.004 * sr)
        attackStep = 1 / (0.003 * sr)
        release = DSP.decay(seconds: 0.018, sampleRate: sr)
        glide = DSP.decay(seconds: 0.035, sampleRate: sr)
        smoothing = DSP.decay(seconds: 0.010, sampleRate: sr)

        kickPitchFast = DSP.decay(seconds: 0.006, sampleRate: sr)
        kickPitchSlow = DSP.decay(seconds: 0.042, sampleRate: sr)
        kickClick = DSP.decay(seconds: 0.0016, sampleRate: sr)
        kickDecay = DSP.decay(seconds: 0.30, sampleRate: sr)
        kickHold = Int(0.018 * sr)
        kickTailStart = Int(0.38 * sr)
        kickTail = DSP.decay(seconds: 0.04, sampleRate: sr)
        kickClickHighpass = expf(-DSP.twoPi * 1_800 / sr)

        snarePitch = DSP.decay(seconds: 0.018, sampleRate: sr)
        snareBody = DSP.decay(seconds: 0.07, sampleRate: sr)
        snareNoise = DSP.decay(seconds: 0.18, sampleRate: sr)
        snareSnap = DSP.decay(seconds: 0.012, sampleRate: sr)

        hatClosed = DSP.decay(seconds: 0.028, sampleRate: sr)
        hatOpen = DSP.decay(seconds: 0.24, sampleRate: sr)

        sidechainAttack = DSP.decay(seconds: 0.0015, sampleRate: sr)
        sidechainRelease = DSP.decay(seconds: 0.065, sampleRate: sr)
    }
}

/// Sine kick with a two-stage pitch envelope (≈470 → 150 → 45 Hz), a noise click and a soft clip.
public struct KickVoice: Sendable, Hashable {
    public private(set) var active = false
    private var fading = false
    private var fade: Float = 1
    private var age = 0
    private var phase: Float = 0
    private var velocity: Float = 0
    private var pitchFast: Float = 0
    private var pitchSlow: Float = 0
    private var amp: Float = 0
    private var click: Float = 0
    private var clickFilter = OnePole()
    private var noise = NoiseSource(seed: 0x9E37_79B9)

    public init() {}

    public mutating func trigger(velocity: Float, _ c: SynthCoefficients) {
        active = true
        fading = false
        fade = 1
        age = 0
        phase = 0
        self.velocity = velocity
        pitchFast = 1
        pitchSlow = 1
        amp = 1
        click = 1
        clickFilter.coefficient = c.kickClickHighpass
    }

    /// Fades the voice out over 4 ms (used when the other kick voice retriggers).
    public mutating func steal() { if active { fading = true } }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> Float {
        guard active else { return 0 }
        pitchFast *= c.kickPitchFast
        pitchSlow *= c.kickPitchSlow
        let frequency = 45 + 105 * pitchSlow + 320 * pitchFast
        phase += frequency * c.invSampleRate
        if phase >= 1 { phase -= 1 }
        if age >= c.kickHold { amp *= age >= c.kickTailStart ? c.kickTail : c.kickDecay }
        click *= c.kickClick
        let n = noise.next()
        let clickSignal = n - clickFilter.lowpass(n)
        var y = sinf(DSP.twoPi * phase) * amp * 1.35 + clickSignal * click * 0.5
        y = DSP.softClip(y * 1.45) * velocity
        age += 1
        if fading {
            fade -= c.stealFadeStep
            if fade <= 0 {
                active = false
                return 0
            }
            y *= fade
        }
        if amp < 0.000_3 { active = false }
        return y
    }
}

/// Snare: a 185 Hz body with a short pitch drop, plus band-passed noise with a snap and a long tail.
public struct SnareVoice: Sendable, Hashable {
    public private(set) var active = false
    private var fading = false
    private var fade: Float = 1
    private var phase: Float = 0
    private var velocity: Float = 0
    private var pitch: Float = 0
    private var body: Float = 0
    private var noiseEnvelope: Float = 0
    private var snap: Float = 0
    private var filter = SVF()
    private var noise: NoiseSource

    public init(seed: UInt32 = 0x2545_F491) {
        noise = NoiseSource(seed: seed)
    }

    public mutating func trigger(velocity: Float, _ c: SynthCoefficients) {
        active = true
        fading = false
        fade = 1
        phase = 0
        self.velocity = velocity
        pitch = 1
        body = 1
        noiseEnvelope = 1
        snap = 1
        filter.set(cutoff: 2_300, resonance: 0.25, sampleRate: c.sampleRate)
    }

    public mutating func steal() { if active { fading = true } }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> Float {
        guard active else { return 0 }
        pitch *= c.snarePitch
        body *= c.snareBody
        noiseEnvelope *= c.snareNoise
        snap *= c.snareSnap
        phase += (185 + 70 * pitch) * c.invSampleRate
        if phase >= 1 { phase -= 1 }
        let tone = sinf(DSP.twoPi * phase) * body
        let filtered = filter.process(noise.next())
        let rattle = (filtered.band * 1.3 + filtered.high * 0.45) * (noiseEnvelope * 0.8 + snap * 0.9)
        var y = DSP.softClip((tone * 0.85 + rattle) * 1.3) * velocity
        if fading {
            fade -= c.stealFadeStep
            if fade <= 0 {
                active = false
                return 0
            }
            y *= fade
        }
        if noiseEnvelope < 0.000_2 { active = false }
        return y
    }
}

/// Closed / open hi-hat: high-passed plus band-passed noise with a short or long decay.
public struct HatVoice: Sendable, Hashable {
    public private(set) var active = false
    public private(set) var isOpen = false
    private var fading = false
    private var fade: Float = 1
    private var velocity: Float = 0
    private var envelope: Float = 0
    private var multiplier: Float = 0
    private var high = SVF()
    private var band = SVF()
    private var noise: NoiseSource
    private var left: Float = 0.707
    private var right: Float = 0.707

    public init(seed: UInt32 = 0x6C07_8965) {
        noise = NoiseSource(seed: seed)
    }

    public mutating func trigger(open: Bool, velocity: Float, pan: Float, _ c: SynthCoefficients) {
        active = true
        fading = false
        fade = 1
        isOpen = open
        self.velocity = velocity
        envelope = 1
        multiplier = open ? c.hatOpen : c.hatClosed
        high.set(cutoff: 7_200, resonance: 0.1, sampleRate: c.sampleRate)
        band.set(cutoff: 10_500, resonance: 0.45, sampleRate: c.sampleRate)
        (left, right) = DSP.pan(pan)
    }

    public mutating func steal() { if active { fading = true } }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> (Float, Float) {
        guard active else { return (0, 0) }
        let n = noise.next()
        var y = (high.process(n).high * 0.55 + band.process(n).band * 0.9) * envelope * velocity
        envelope *= multiplier
        if fading {
            fade -= c.stealFadeStep
            if fade <= 0 {
                active = false
                return (0, 0)
            }
            y *= fade
        }
        if envelope < 0.000_2 { active = false }
        return (y * left, y * right)
    }
}
