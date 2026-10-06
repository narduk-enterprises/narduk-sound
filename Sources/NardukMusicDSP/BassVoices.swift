import Foundation
import NardukMusicCore

/// A wobble bass patch; `NoteParams.voice` selects one (voice mod `count`). Trivially
/// copyable and built by a switch, so choosing one on the render thread never allocates.
public struct WobblePatch: Sendable, Hashable, BitwiseCopyable {
    public var sawMix: Float
    public var detuneCents: Float
    public var squareMix: Float
    public var subSquareMix: Float
    public var fmMix: Float
    public var baseCutoff: Float
    public var depthOctaves: Float
    public var resonance: Float
    public var drive: Float
    public var formantMix: Float

    public init(
        sawMix: Float, detuneCents: Float, squareMix: Float, subSquareMix: Float, fmMix: Float,
        baseCutoff: Float, depthOctaves: Float, resonance: Float, drive: Float, formantMix: Float
    ) {
        self.sawMix = sawMix
        self.detuneCents = detuneCents
        self.squareMix = squareMix
        self.subSquareMix = subSquareMix
        self.fmMix = fmMix
        self.baseCutoff = baseCutoff
        self.depthOctaves = depthOctaves
        self.resonance = resonance
        self.drive = drive
        self.formantMix = formantMix
    }

    /// Base patches; `voice % count` picks one.
    public static let count = BassPatches.count
    /// Character variants of each base patch; `(voice / count) % variantCount` picks one, so 36 ... 47 distinct basses.
    public static let variantCount = BassPatches.variantCount
    public static let names = BassPatches.names

    public static func patch(for voice: Int) -> WobblePatch {
        let v = max(voice, 0)
        var patch = basePatch(v % count)
        patch.applyVariant((v / count) % variantCount)
        return patch
    }

    /// Bends a base patch into one of its characters: wider or tighter detune, a brighter or darker filter, more or
    /// less resonance and sweep, an FM edge, a vowel lean. Every variant stays inside the stable ranges.
    mutating func applyVariant(_ variant: Int) {
        guard variant > 0 else { return }
        let detune: [Float] = [1, 0.55, 1.6, 1.2, 0.8, 1.9, 1.0, 0.7]
        let cutoff: [Float] = [1, 1.3, 0.8, 1.15, 0.9, 1.45, 1.0, 0.75]
        let res: [Float] = [0, 0.08, -0.12, 0.05, -0.06, 0.1, -0.18, 0.02]
        let depth: [Float] = [0, -0.5, 0.4, 0.2, -0.3, 0.3, -0.2, 0.5]
        let fm: [Float] = [0, 0, 0, 0.35, 0, 0.15, 0.5, 0]
        let vowel: [Float] = [0, 0.1, -0.12, 0, 0.22, -0.05, 0.1, 0.18]
        let square: [Float] = [0, 0.2, 0, -0.15, 0.3, 0, 0.1, -0.1]
        detuneCents *= detune[variant]
        baseCutoff *= cutoff[variant]
        resonance = min(max(resonance + res[variant], 0.15), 0.9)
        depthOctaves = min(max(depthOctaves + depth[variant], 4), 6.6)
        fmMix = min(fmMix + fm[variant], 1)
        formantMix = min(max(formantMix + vowel[variant], 0.05), 0.85)
        squareMix = min(max(squareMix + square[variant], 0), 1)
    }

    static func basePatch(_ index: Int) -> WobblePatch {
        switch index {
        case 1:
            WobblePatch(
                sawMix: 1.0, detuneCents: 26, squareMix: 0, subSquareMix: 0.6, fmMix: 0,
                baseCutoff: 120, depthOctaves: 5.0, resonance: 0.35, drive: 0.45, formantMix: 0.2)
        case 2:
            WobblePatch(
                sawMix: 0.2, detuneCents: 8, squareMix: 0.9, subSquareMix: 0.7, fmMix: 0,
                baseCutoff: 80, depthOctaves: 6.3, resonance: 0.82, drive: 0.35, formantMix: 0.3)
        case 3:
            WobblePatch(
                sawMix: 0.3, detuneCents: 10, squareMix: 0, subSquareMix: 0.5, fmMix: 1.0,
                baseCutoff: 150, depthOctaves: 5.5, resonance: 0.6, drive: 0.8, formantMix: 0.5)
        case 4:
            WobblePatch(
                sawMix: 0.8, detuneCents: 12, squareMix: 0.2, subSquareMix: 0.5, fmMix: 0,
                baseCutoff: 100, depthOctaves: 5.6, resonance: 0.5, drive: 0.5, formantMix: 0.75)
        case 5:
            WobblePatch(
                sawMix: 0.45, detuneCents: 6, squareMix: 0.65, subSquareMix: 0.6, fmMix: 0,
                baseCutoff: 70, depthOctaves: 6.4, resonance: 0.86, drive: 0.9, formantMix: 0.25)
        default:
            WobblePatch(
                sawMix: 0.75, detuneCents: 14, squareMix: 0.3, subSquareMix: 0.55, fmMix: 0,
                baseCutoff: 90, depthOctaves: 6.0, resonance: 0.72, drive: 0.6, formantMix: 0.45)
        }
    }
}

/// Folds a MIDI note by octaves into `low ... high` (keeps riffs in a playable bass register).
@inline(__always) func foldPitch(_ note: Float, low: Float, high: Float) -> Float {
    var p = note
    while p > high { p -= 12 }
    while p < low { p += 12 }
    return p
}

/// The wobble: 3 detuned saws + square + square sub-osc (or an FM screech), driven into a
/// resonant TPT lowpass whose cutoff rides a tempo-synced LFO, blended with a pair of
/// LFO-swept formant band-passes ("wub" vs "yoi"). Monophonic with glide.
public struct WobbleVoice: Sendable {
    public private(set) var active = false
    private var gate = 0
    private var amp: Float = 0
    private var velocity: Float = 0
    private var logFrequency: Float = 6
    private var targetLogFrequency: Float = 6
    private var phases: (Float, Float, Float, Float, Float, Float) = (0, 0.33, 0.67, 0.1, 0.5, 0)
    public private(set) var lfoPhase: Float = 0
    private var lfoIncrement: Float = 0
    private var sawMix: Float = 0
    private var detune: Float = 1
    private var squareMix: Float = 0
    private var subSquareMix: Float = 0
    private var fmMix: Float = 0
    private var baseCutoff: Float = 100
    private var depthOctaves: Float = 6
    private var resonance: Float = 0.7
    private var drive: Float = 0.5
    private var formant: Float = 0.5
    private var formantMix: Float = 0.4
    private var left: Float = 0.707
    private var right: Float = 0.707
    private var lowpass = SVF()
    private var formant1 = SVF()
    private var formant2 = SVF()
    private var dcBlock = OnePole()
    private var glideCoefficient: Float = 0.999
    /// The current filter cutoff in Hz (for the visualizer).
    public private(set) var cutoff: Float = 20

    public init() {}

    public mutating func noteOn(
        pitch: Float, gateSamples: Int, cyclesPerBeat: Float, bpm: Float, formant: Float,
        drive: Float, voice: Int, velocity: Float, pan: Float, glide: Float = -1, _ c: SynthCoefficients
    ) {
        glideCoefficient = glide < 0 ? c.glide : DSP.decay(seconds: 0.035 + 0.215 * glide, sampleRate: c.sampleRate)
        let note = foldPitch(pitch < 0 ? 41 : pitch, low: 33, high: 56)
        targetLogFrequency = log2f(DSP.midiToHz(note))
        let legato = active && amp > 0.001
        if !legato {
            logFrequency = targetLogFrequency
            amp = 0
            lowpass.reset()
            formant1.reset()
            formant2.reset()
        }
        let patch = WobblePatch.patch(for: voice)
        sawMix = patch.sawMix
        detune = exp2f(patch.detuneCents / 1_200)
        squareMix = patch.squareMix
        subSquareMix = patch.subSquareMix
        fmMix = patch.fmMix
        baseCutoff = patch.baseCutoff
        depthOctaves = patch.depthOctaves
        resonance = patch.resonance
        formantMix = patch.formantMix
        self.drive = drive < 0 ? patch.drive : drive
        self.formant = formant < 0 ? 0.5 : formant
        self.velocity = velocity
        let rate = cyclesPerBeat > 0 ? cyclesPerBeat : 1
        lfoIncrement = rate * bpm / 60 * c.invSampleRate
        lfoPhase = 0
        gate = max(gateSamples, 1)
        active = true
        dcBlock.setCutoff(28, sampleRate: c.sampleRate)
        (left, right) = DSP.pan(pan * 0.5)
    }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> (Float, Float) {
        guard active else { return (0, 0) }
        if gate > 0 {
            gate -= 1
            amp = min(1, amp + c.attackStep)
        } else {
            amp *= c.release
            if amp < 0.000_1 {
                active = false
                return (0, 0)
            }
        }
        logFrequency = targetLogFrequency + (logFrequency - targetLogFrequency) * glideCoefficient
        let frequency = exp2f(logFrequency)
        let dt = frequency * c.invSampleRate

        // Oscillators.
        phases.0 = DSP.wrap(phases.0 + dt)
        phases.1 = DSP.wrap(phases.1 + dt * detune)
        phases.2 = DSP.wrap(phases.2 + dt / detune)
        phases.3 = DSP.wrap(phases.3 + dt)
        phases.4 = DSP.wrap(phases.4 + dt * 0.5)
        phases.5 = DSP.wrap(phases.5 + dt * 2.002)
        var osc: Float = 0
        if sawMix > 0 {
            osc +=
                (DSP.saw(phases.0, dt) + DSP.saw(phases.1, dt * detune) + DSP.saw(phases.2, dt / detune))
                * (sawMix / 2.2)
        }
        if squareMix > 0 { osc += DSP.square(phases.3, dt) * squareMix * 0.7 }
        osc += DSP.square(phases.4, dt * 0.5) * subSquareMix * 0.6

        // Tempo-synced LFO: 0 at each note start, fully open mid-cycle.
        lfoPhase += lfoIncrement
        if lfoPhase >= 1 { lfoPhase -= 1 }
        let mod = 0.5 - 0.5 * cosf(DSP.twoPi * lfoPhase)

        if fmMix > 0 {
            let index = 1.2 + 4.5 * mod
            osc += sinf(DSP.twoPi * phases.0 + index * sinf(DSP.twoPi * phases.5)) * fmMix
        }

        let driven = DSP.softClip(osc * (1 + drive * 5))
        let brightness = 0.7 + 0.6 * formant
        let floorCutoff = max(baseCutoff, frequency * 1.5)
        cutoff = min(floorCutoff * brightness * exp2f(depthOctaves * mod * (0.65 + 0.35 * velocity)), 16_000)
        lowpass.set(cutoff: cutoff, resonance: resonance, sampleRate: c.sampleRate)
        let low = lowpass.process(driven).low

        // Formant pair: "wub" sweeps u → a, "yoi" sweeps o → i; `formant` blends them.
        let wubF1 = 300 + 430 * mod
        let wubF2 = 870 + 220 * mod
        let yoiF1 = 570 - 300 * mod
        let yoiF2 = 840 + 1_450 * mod
        let f1 = yoiF1 + (wubF1 - yoiF1) * formant
        let f2 = yoiF2 + (wubF2 - yoiF2) * formant
        formant1.set(cutoff: f1, resonance: 0.9, sampleRate: c.sampleRate)
        formant2.set(cutoff: f2, resonance: 0.9, sampleRate: c.sampleRate)
        let vowel = (formant1.process(driven).band + formant2.process(driven).band * 0.7) * 1.8 * (0.45 + 0.55 * mod)

        var y = low * (1 - formantMix) + vowel * formantMix
        y = DSP.softClip(y * 1.4) * 0.8
        y = dcBlock.highpass(y) * amp * velocity
        return (y * left, y * right)
    }

    /// Cutoff normalized 0 ... 1 on a log scale from 20 Hz to 20 kHz.
    public var normalizedCutoff: Float {
        min(max(log2f(max(cutoff, 20) / 20) / log2f(1_000), 0), 1)
    }
}

/// A clean sine sub one octave below the bass register, with glide and a little saturation.
public struct SubVoice: Sendable, Hashable {
    public private(set) var active = false
    private var gate = 0
    private var amp: Float = 0
    private var velocity: Float = 0
    private var phase: Float = 0
    private var logFrequency: Float = 5
    private var targetLogFrequency: Float = 5
    private var glideCoefficient: Float = 0.999

    public init() {}

    public mutating func noteOn(
        pitch: Float, gateSamples: Int, velocity: Float, glide: Float = -1, _ c: SynthCoefficients
    ) {
        glideCoefficient = glide < 0 ? c.glide : DSP.decay(seconds: 0.035 + 0.215 * glide, sampleRate: c.sampleRate)
        let note = foldPitch(pitch < 0 ? 29 : pitch, low: 24, high: 40)
        targetLogFrequency = log2f(DSP.midiToHz(note))
        if !(active && amp > 0.001) {
            logFrequency = targetLogFrequency
            amp = 0
            phase = 0
        }
        gate = max(gateSamples, 1)
        self.velocity = velocity
        active = true
    }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> Float {
        guard active else { return 0 }
        if gate > 0 {
            gate -= 1
            amp = min(1, amp + c.attackStep * 0.6)
        } else {
            amp *= c.release
            if amp < 0.000_1 {
                active = false
                return 0
            }
        }
        logFrequency = targetLogFrequency + (logFrequency - targetLogFrequency) * glideCoefficient
        phase += exp2f(logFrequency) * c.invSampleRate
        if phase >= 1 { phase -= 1 }
        return DSP.softClip(sinf(DSP.twoPi * phase) * 1.25) * amp * velocity
    }
}
