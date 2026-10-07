import Foundation
import NardukMusicCore

/// Which ambient sound a `PadVoice` makes.
public enum AmbientKind: UInt8, Sendable, Hashable, BitwiseCopyable {
    case pad, drone

    /// The kind a `.keys` note's voice value asks for (`KeysVoice.ambientPad`, `KeysVoice.drone`), or nil for the
    /// ordinary keys timbres.
    public init?(voice: Int) {
        switch voice {
        case KeysVoice.ambientPad: self = .pad
        case KeysVoice.drone: self = .drone
        default: return nil
        }
    }
}

/// One pooled voice for the ambient family's chords and drones: three detuned band-limited saws (a sine sub for the
/// drone) spread across the stereo field, through a lowpass whose cutoff drifts on a very slow LFO, under a swell
/// envelope that takes seconds to open and seconds to close. Plain trivially copyable state: no allocation.
public struct PadVoice: Sendable, Hashable {
    public private(set) var active = false
    private var kind = AmbientKind.pad
    private var age = 0
    private var gateEnd = 0
    private var baseHz: Float = 220
    private var phaseA: Float = 0
    private var phaseB: Float = 0
    private var phaseC: Float = 0
    private var phaseSub: Float = 0
    private var lfoPhase: Float = 0
    private var lfoStep: Float = 0
    private var envelope: Float = 0
    private var attack: Float = 0
    private var release: Float = 0
    private var level: Float = 0
    private var cutoff: Float = 900
    private var detune: Float = 1.004
    private var filterLeft = SVF()
    private var filterRight = SVF()

    /// Seconds the swell takes to open and to close; a note's gate may be shorter, never the release.
    public static let padAttack: Float = 1.6
    public static let padRelease: Float = 3.0
    public static let droneAttack: Float = 4.0
    public static let droneRelease: Float = 6.0

    public init() {}

    /// The samples after the gate a voice keeps sounding (its release plus a margin), for sizing a tail.
    public static func releaseSamples(_ kind: AmbientKind, sampleRate: Float) -> Int {
        Int((kind == .pad ? padRelease : droneRelease) * 6 * sampleRate)
    }

    public mutating func noteOn(
        _ kind: AmbientKind, pitch: Float, gateSamples: Int, velocity: Float, _ c: SynthCoefficients
    ) {
        let sr = c.sampleRate
        self.kind = kind
        let note: Float =
            kind == .pad
            ? foldPitch(pitch < 0 ? 57 : pitch, low: 45, high: 76)
            : foldPitch(pitch < 0 ? 33 : pitch, low: 24, high: 45)
        baseHz = DSP.midiToHz(note)
        age = 0
        gateEnd = max(gateSamples, Int(0.25 * sr))
        active = true
        envelope = 0
        level = velocity
        attack = 1 - expf(-1 / ((kind == .pad ? PadVoice.padAttack : PadVoice.droneAttack) * sr / 3))
        release = 1 - expf(-1 / ((kind == .pad ? PadVoice.padRelease : PadVoice.droneRelease) * sr / 3))
        detune = kind == .pad ? 1.0045 : 1.0022
        // The LFO's rate and start depend on the pitch, so voices on different notes drift apart; the same note always
        // drifts the same way (the render stays deterministic).
        let fraction = note * 0.37 - floorf(note * 0.37)
        lfoStep = (0.05 + 0.09 * fraction) * c.invSampleRate
        lfoPhase = fraction
        phaseA = fraction
        phaseB = DSP.wrap(fraction * 3.1)
        phaseC = DSP.wrap(fraction * 5.7)
        phaseSub = 0
        cutoff = kind == .pad ? 1_100 : 260
        filterLeft.reset()
        filterRight.reset()
    }

    /// Starts the release now (a stolen voice).
    public mutating func steal() {
        if active { gateEnd = min(gateEnd, age) }
    }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> (Float, Float) {
        guard active else { return (0, 0) }
        let gated = age < gateEnd
        if gated {
            envelope += (1 - envelope) * attack
        } else {
            envelope += (0 - envelope) * release
            if envelope < 1e-4 {
                active = false
                return (0, 0)
            }
        }
        age += 1
        let dt = baseHz * c.invSampleRate
        phaseA = DSP.wrap(phaseA + dt / detune)
        phaseB = DSP.wrap(phaseB + dt)
        phaseC = DSP.wrap(phaseC + dt * detune)
        lfoPhase = DSP.wrap(lfoPhase + lfoStep)
        let lfo = sinf(DSP.twoPi * lfoPhase)
        let sawA = DSP.saw(phaseA, dt / detune)
        let sawB = DSP.saw(phaseB, dt)
        let sawC = DSP.saw(phaseC, dt * detune)
        // The two ears hear the stack in opposite orders, and their filters drift in opposite directions.
        var rawLeft = sawA * 0.9 + sawB * 0.6 + sawC * 0.25
        var rawRight = sawC * 0.9 + sawB * 0.6 + sawA * 0.25
        if kind == .drone {
            phaseSub = DSP.wrap(phaseSub + dt * 0.5)
            let sub = sinf(DSP.twoPi * phaseSub) * 0.9
            rawLeft = rawLeft * 0.45 + sub
            rawRight = rawRight * 0.45 + sub
        }
        // Open the filter as the swell opens, and let it breathe around that.
        let open = 0.35 + 0.65 * envelope
        let drift: Float = 0.45 * (kind == .pad ? 1 : 0.6)
        filterLeft.set(cutoff: cutoff * open * (1 + drift * lfo), resonance: 0.18, sampleRate: c.sampleRate)
        filterRight.set(cutoff: cutoff * open * (1 - drift * lfo), resonance: 0.18, sampleRate: c.sampleRate)
        let gain = envelope * level * (kind == .pad ? 0.2 : 0.28)
        return (filterLeft.process(rawLeft).low * gain, filterRight.process(rawRight).low * gain)
    }
}

/// The send levels and times of the ambient chain, set from outside and read by the render thread each buffer.
public struct AmbientSpace: Sendable, Hashable {
    /// Seconds the hall's tail takes to fall 60 dB.
    public var reverbSeconds: Float = 9
    /// 0 ... 1 of the ambient signal sent to the hall, and how loud the hall is in the mix.
    public var reverbMix: Float = 0.7
    /// 0 ... 1 of the ambient signal echoed, and how loud the echoes are in the mix.
    public var delayMix: Float = 0.35
    /// Share of each echo fed back, 0 ... 0.95.
    public var delayFeedback: Float = 0.55
    /// Echo spacing in sixteenth notes at the song's tempo (6 is a dotted eighth).
    public var delaySteps: Float = 6
    /// 0 ... 1.5 gain of the dry pads and drones.
    public var padLevel: Float = 1

    public init() {}

    public init(
        reverbSeconds: Float = 9, reverbMix: Float = 0.7, delayMix: Float = 0.35, delayFeedback: Float = 0.55,
        delaySteps: Float = 6, padLevel: Float = 1
    ) {
        self.reverbSeconds = reverbSeconds
        self.reverbMix = reverbMix
        self.delayMix = delayMix
        self.delayFeedback = delayFeedback
        self.delaySteps = delaySteps
        self.padLevel = padLevel
    }
}
