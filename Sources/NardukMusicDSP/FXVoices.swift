import Foundation
import NardukMusicCore

public enum FXKind: UInt8, Sendable, Hashable, BitwiseCopyable {
    case laser, scratch, vox, riser, impact, blip, keys
}

/// One pooled voice for every one-shot effect. `kind` selects the algorithm; the
/// voice carries a handful of generic oscillators, envelopes and filters.
public struct FXVoice: Sendable, Hashable {
    public private(set) var active = false
    public private(set) var kind: FXKind = .laser
    private var fading = false
    private var fade: Float = 1
    private var age = 0
    private var length = 1
    private var velocity: Float = 0
    private var baseHz: Float = 440
    private var left: Float = 0.707
    private var right: Float = 0.707
    private var phaseA: Float = 0
    private var phaseB: Float = 0
    private var phaseC: Float = 0
    private var phaseD: Float = 0
    private var env1: Float = 0, env2: Float = 0, env3: Float = 0, env4: Float = 0, env5: Float = 0
    private var mul1: Float = 0, mul2: Float = 0, mul3: Float = 0, mul4: Float = 0, mul5: Float = 0
    private var filterA = SVF()
    private var filterB = SVF()
    private var filterC = SVF()
    private var noiseLeft: NoiseSource
    private var noiseRight: NoiseSource
    private var held: Float = 0
    private var holdCounter = 0
    // Keys: which timbre, and the sample where the key is released.
    private var timbre = 0
    /// A pumping pad (`KeysVoice.pumpPad`): the mixer ducks it on a slower sidechain of its own.
    public private(set) var pumps = false
    /// A melodic library voice (`KeysVoice.marimba` and `panFlute` ... `softPiano`): the mixer ducks it lightly (about
    /// 3 dB) instead of the effects' 6 dB dip, so a melody breathes with the kick rather than pumps.
    public private(set) var ducksLightly = false
    private var gateEnd = 0
    // Vox vowel: first two formants as start + sweep over the note.
    private var f1Start: Float = 450, f1Sweep: Float = 300, f2Start: Float = 800, f2Sweep: Float = 350

    public init(seed: UInt32 = 0x1F12_3BB5) {
        noiseLeft = NoiseSource(seed: seed)
        noiseRight = NoiseSource(seed: seed &* 2_654_435_761 | 1)
    }

    public mutating func trigger(
        _ kind: FXKind, pitch: Float, lengthSamples: Int, velocity: Float, pan: Float,
        voice: Int = -1, _ c: SynthCoefficients
    ) {
        let sr = c.sampleRate
        self.kind = kind
        pumps = false
        ducksLightly = false
        active = true
        fading = false
        fade = 1
        age = 0
        self.velocity = velocity
        phaseA = 0
        phaseB = 0.37
        phaseC = 0.71
        phaseD = 0
        filterA.reset()
        filterB.reset()
        filterC.reset()
        held = 0
        holdCounter = 0
        (left, right) = DSP.pan(pan)
        switch kind {
        case .laser:
            baseHz = min(max(DSP.midiToHz(pitch < 0 ? 96 : pitch), 600), 5_000)
            length = Int(min(max(Float(lengthSamples), 0.16 * sr), 0.45 * sr))
        case .scratch:
            length = Int(min(max(Float(lengthSamples), 0.15 * sr), 1.0 * sr))
        case .vox:
            baseHz = DSP.midiToHz(foldPitch(pitch < 0 ? 53 : pitch, low: 45, high: 60))
            length = Int(min(max(Float(lengthSamples), 0.12 * sr), 2.0 * sr))
            // voice picks the vowel: "oh" (default), "ah", "ee", "oo".
            switch max(voice, 0) % 4 {
            case 1: (f1Start, f1Sweep, f2Start, f2Sweep) = (700, 80, 1_100, 180)
            case 2: (f1Start, f1Sweep, f2Start, f2Sweep) = (300, 120, 2_150, 350)
            case 3: (f1Start, f1Sweep, f2Start, f2Sweep) = (340, 160, 720, 260)
            default: (f1Start, f1Sweep, f2Start, f2Sweep) = (450, 300, 800, 350)
            }
        case .riser:
            baseHz = DSP.midiToHz(foldPitch(pitch < 0 ? 48 : pitch, low: 40, high: 60))
            length = max(lengthSamples, Int(0.2 * sr))
        case .impact:
            length = Int(2.8 * sr)
            env1 = 1
            mul1 = DSP.decay(seconds: 0.07, sampleRate: sr)  // boom pitch
            env2 = 1
            mul2 = DSP.decay(seconds: 0.9, sampleRate: sr)  // boom amp
            env3 = 1
            mul3 = DSP.decay(seconds: 0.22, sampleRate: sr)  // burst amp
            env4 = 1
            mul4 = DSP.decay(seconds: 0.12, sampleRate: sr)  // burst filter
            env5 = 1
            mul5 = DSP.decay(seconds: 1.4, sampleRate: sr)  // tail
            filterB.set(cutoff: 700, resonance: 0.2, sampleRate: sr)
        case .blip:
            baseHz = 1_600
            length = Int(0.07 * sr)
        case .keys:
            // voice picks the timbre: 0 bell pluck, 1 house stab, 2 electric piano, 3 pad, 4 marimba; 5 is the pad
            // on the pumping sidechain; 6 pan flute, 7 steel drum, 8 sax-like lead, 9 soft piano.
            pumps = voice == KeysVoice.pumpPad
            let library = voice >= KeysVoice.panFlute && voice <= KeysVoice.softPiano
            ducksLightly = library || voice == KeysVoice.marimba
            timbre = voice == KeysVoice.marimba ? 4 : pumps ? 3 : library ? voice : max(voice, 0) % 4
            // Each library voice keeps to its instrument's own register; the first five share the keys' one.
            let (low, high): (Float, Float) =
                switch timbre {
                case 6: (60, 91)
                case 7: (55, 86)
                case 8: (46, 79)
                default: (48, 88)
                }
            baseHz = DSP.midiToHz(foldPitch(pitch < 0 ? 72 : pitch, low: low, high: high))
            let gate = Float(lengthSamples)
            let (minimum, maximum, ampDecay, toneDecay, release): (Float, Float, Float, Float, Float) =
                switch timbre {
                case 0: (0.2, 1.2, 0.38, 0.07, 0.09)
                case 1: (0.06, 0.5, 0.2, 0.06, 0.05)
                case 2: (0.2, 2.5, 1.1, 0.03, 0.22)
                case 4: (0.12, 0.7, 0.3, 0.05, 0.07)
                case 6: (0.15, 3.0, 30, 0.07, 0.12)  // flute: held; the breath chiff dies
                case 7: (0.15, 1.6, 0.55, 0.18, 0.09)  // steel drum: struck; the bright strike dies first
                case 8: (0.12, 3.0, 30, 0.12, 0.1)  // sax: held; the breath bloom closes
                case 9: (0.3, 3.0, 1.6, 0.25, 0.3)  // soft piano: a long mellow decay
                default: (0.4, 4.0, 60, 1, 0.45)
                }
            switch timbre {
            case 4:
                env3 = 1
                mul3 = DSP.decay(seconds: 0.012, sampleRate: sr)  // the mallet knock
            case 6:
                filterA.set(cutoff: min(baseHz * 2, 6_000), resonance: 0.35, sampleRate: sr)  // the breath band
                filterB.set(cutoff: 7_000, resonance: 0.1, sampleRate: sr)  // the flute's soft top
            case 7:
                env3 = 1
                mul3 = DSP.decay(seconds: 0.06, sampleRate: sr)  // the inharmonic ring
                env4 = 1
                mul4 = DSP.decay(seconds: 0.022, sampleRate: sr)  // the stick's FM strike
            case 8:
                filterB.set(cutoff: 520, resonance: 0.6, sampleRate: sr)  // first formant
                filterC.set(cutoff: 1_450, resonance: 0.55, sampleRate: sr)  // second formant
            case 9:
                env3 = 1
                mul3 = DSP.decay(seconds: 0.01, sampleRate: sr)  // the felt hammer
                filterA.set(cutoff: 900, resonance: 0.1, sampleRate: sr)
            default:
                break
            }
            gateEnd = Int(min(max(gate, minimum * sr), maximum * sr))
            length = gateEnd + Int(release * 6 * sr)
            env1 = 1
            mul1 = DSP.decay(seconds: ampDecay, sampleRate: sr)  // amp
            env2 = 1
            mul2 = DSP.decay(seconds: toneDecay, sampleRate: sr)  // brightness / FM index / tine
            env5 = 1
            mul5 = DSP.decay(seconds: release, sampleRate: sr)  // release after the gate
        }
        length = max(length, 1)
    }

    public mutating func steal() { if active { fading = true } }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> (Float, Float) {
        guard active else { return (0, 0) }
        let sr = c.sampleRate
        let p = Float(age) / Float(length)
        // A 5 ms fade at the end of every effect.
        let tail = min(Float(length - age) * c.invSampleRate * 200, 1)
        var outLeft: Float = 0
        var outRight: Float = 0

        switch kind {
        case .laser:
            let frequency = max(baseHz * exp2f(-5 * p), 70)
            let dt = frequency * c.invSampleRate
            phaseA = DSP.wrap(phaseA + dt)
            phaseB = DSP.wrap(phaseB + dt * 1.01)
            let wave = DSP.square(phaseA, dt) * 0.6 + DSP.saw(phaseB, dt * 1.01) * 0.4
            filterA.set(cutoff: min(frequency * 4, 12_000), resonance: 0.7, sampleRate: sr)
            let attack = min(Float(age) * c.invSampleRate * 1_000, 1)
            let y = filterA.process(wave).low * (1 - p) * (1 - p) * attack * 0.55
            outLeft = y * left
            outRight = y * right

        case .scratch:
            let speed = sinf(DSP.twoPi * p * 1.5)
            let s = abs(speed)
            let frequency = 120 + 1_100 * s
            let dt = frequency * c.invSampleRate
            phaseA = DSP.wrap(phaseA + dt)
            filterA.set(cutoff: 400 + 2_600 * s, resonance: 0.6, sampleRate: sr)
            let grit = filterA.process(noiseLeft.next()).band
            filterB.set(cutoff: 3_500, resonance: 0.1, sampleRate: sr)
            let raw = DSP.saw(phaseA, dt) * 0.45 + grit * 1.1
            let y = filterB.process(raw).low * powf(s, 0.6) * 0.6
            outLeft = y * left
            outRight = y * right

        case .vox:
            let seconds = Float(age) * c.invSampleRate
            let vibrato = seconds > 0.08 ? 1 + 0.015 * sinf(DSP.twoPi * 5.5 * seconds) : 1
            let dt = baseHz * vibrato * c.invSampleRate
            phaseA = DSP.wrap(phaseA + dt)
            var shifted = phaseA + 0.32
            if shifted >= 1 { shifted -= 1 }
            let pulse = DSP.saw(phaseA, dt) - DSP.saw(shifted, dt)
            filterA.set(cutoff: f1Start + f1Sweep * p, resonance: 0.9, sampleRate: sr)
            filterB.set(cutoff: f2Start + f2Sweep * p, resonance: 0.9, sampleRate: sr)
            filterC.set(cutoff: 2_600, resonance: 0.85, sampleRate: sr)
            let voiced =
                filterA.process(pulse).band + filterB.process(pulse).band * 0.8 + filterC.process(pulse).band * 0.35
            let attack = min(seconds * 125, 1)
            let y = DSP.softClip(voiced * 1.6) * attack * 0.6
            outLeft = y * left
            outRight = y * right

        case .riser:
            let center = 300 * exp2f(5 * p)
            filterA.set(cutoff: center, resonance: 0.55, sampleRate: sr)
            filterB.set(cutoff: center * 1.07, resonance: 0.55, sampleRate: sr)
            let hissLeft = filterA.process(noiseLeft.next()).band
            let hissRight = filterB.process(noiseRight.next()).band
            let frequency = baseHz * exp2f(2 * p)
            let dt = frequency * c.invSampleRate
            phaseA = DSP.wrap(phaseA + dt)
            phaseB = DSP.wrap(phaseB + dt * 1.006)
            filterC.set(cutoff: 400 * exp2f(4.5 * p), resonance: 0.4, sampleRate: sr)
            let saws = filterC.process(DSP.saw(phaseA, dt) + DSP.saw(phaseB, dt * 1.006)).low * 0.3
            let amp = p * p * 0.7
            outLeft = (hissLeft * 0.9 + saws) * amp
            outRight = (hissRight * 0.9 + saws) * amp

        case .impact:
            env1 *= mul1
            env2 *= mul2
            env3 *= mul3
            env4 *= mul4
            env5 *= mul5
            phaseA += (32 + 48 * env1) * c.invSampleRate
            if phaseA >= 1 { phaseA -= 1 }
            let boom = DSP.softClip(sinf(DSP.twoPi * phaseA) * env2 * 1.4) * 0.85
            filterA.set(cutoff: 80 + 7_000 * env4, resonance: 0.1, sampleRate: sr)
            let burst = filterA.process(noiseLeft.next()).low * env3 * 0.5
            let rumble = filterB.process(noiseRight.next()).low * env5 * 0.35
            outLeft = boom + burst + rumble
            outRight = boom + burst * 0.8 + rumble * 1.1

        case .keys:
            let seconds = Float(age) * c.invSampleRate
            let dt = baseHz * c.invSampleRate
            env1 *= mul1
            env2 *= mul2
            if age >= gateEnd { env5 *= mul5 }
            phaseA = DSP.wrap(phaseA + dt)
            var y: Float
            switch timbre {
            case 0:
                // Bell pluck: a sine with a decaying inharmonic FM shimmer.
                phaseB = DSP.wrap(phaseB + dt * 3.5)
                y = sinf(DSP.twoPi * phaseA + (0.25 + 2.4 * env2) * sinf(DSP.twoPi * phaseB)) * env1 * 0.3
            case 1:
                // House stab: detuned saws and a square through a snappy lowpass.
                phaseB = DSP.wrap(phaseB + dt * 1.008)
                phaseC = DSP.wrap(phaseC + dt * 0.992)
                let raw =
                    DSP.saw(phaseA, dt) + DSP.saw(phaseB, dt * 1.008) * 0.8 + DSP.square(phaseC, dt * 0.992) * 0.35
                filterA.set(cutoff: 320 + 4_600 * env2, resonance: 0.35, sampleRate: sr)
                y = filterA.process(raw).low * env1 * 0.2
            case 2:
                // Electric piano: a sine with a little second harmonic, a short tine and a slow tremolo.
                phaseB = DSP.wrap(phaseB + dt * 14)
                let tremolo = 1 + 0.12 * sinf(DSP.twoPi * 4.5 * seconds)
                y =
                    (sinf(DSP.twoPi * phaseA) + 0.18 * sinf(2 * DSP.twoPi * phaseA) + 0.3 * env2
                        * sinf(DSP.twoPi * phaseB))
                    * env1 * tremolo * 0.26
            case 4:
                // Marimba: a sine bar, its fourth-partial overtone (a tuned bar's second mode) dying fast, and a short
                // inharmonic knock from the mallet. A 1 ms ramp keeps the onset soft.
                phaseB = DSP.wrap(phaseB + dt * 4)
                phaseC = DSP.wrap(phaseC + dt * 9.8)
                env3 *= mul3
                let attack = min(seconds * 1_000, 1)
                y =
                    (sinf(DSP.twoPi * phaseA) + 0.45 * env2 * sinf(DSP.twoPi * phaseB) + 0.2 * env3
                        * sinf(DSP.twoPi * phaseC)) * env1 * attack * 0.3
            case 6:
                // Pan flute: a soft sine with a whisper of its second and third harmonics, under a band of breath
                // noise that chiffs at the onset and settles to a steady air. A 60 ms attack, and from 0.25 s a
                // vibrato that eases in to about 0.5 %.
                let ease = min(max((seconds - 0.25) * 2.5, 0), 1)
                let vibrato = 1 + 0.005 * ease * sinf(DSP.twoPi * 5 * seconds)
                phaseA = DSP.wrap(phaseA + dt * (vibrato - 1))
                phaseB = DSP.wrap(phaseB + dt * 2 * vibrato)
                phaseC = DSP.wrap(phaseC + dt * 3 * vibrato)
                let attack = min(seconds * 16.7, 1)
                let tone =
                    sinf(DSP.twoPi * phaseA) + 0.12 * sinf(DSP.twoPi * phaseB) + 0.05 * sinf(DSP.twoPi * phaseC)
                let breath = filterA.process(noiseLeft.next()).band * (0.1 + 0.55 * env2)
                y = filterB.process(tone * attack + breath * min(seconds * 40, 1)).low * 0.24
            case 7:
                // Steel drum: a carrier on the fundamental, struck by a fast-dying FM bite, with the pan's tuned
                // octave and a slightly sharp twelfth that die at their own rates, over a short inharmonic ring.
                // A 1.5 ms ramp keeps the bright onset from clicking.
                env3 *= mul3
                env4 *= mul4
                phaseB = DSP.wrap(phaseB + dt * 2)
                phaseC = DSP.wrap(phaseC + dt * 3.02)
                phaseD = DSP.wrap(phaseD + dt * 4.27)
                let attack = min(seconds * 667, 1)
                let bite = 1.6 * env4 * sinf(DSP.twoPi * phaseD)
                y =
                    (sinf(DSP.twoPi * phaseA + bite) + 0.6 * env2 * sinf(DSP.twoPi * phaseB) + 0.3 * env2 * env2
                        * sinf(DSP.twoPi * phaseC) + 0.25 * env3 * sinf(DSP.twoPi * phaseD * 1.37))
                    * env1 * attack * 0.22
            case 8:
                // Sax-like lead: a saw whose lowpass opens with the breath and sits a few harmonics up, voiced by two
                // formants, with a little breath noise. A 30 ms attack, and from 0.2 s a vibrato easing in to 0.7 %.
                let ease = min(max((seconds - 0.2) * 3, 0), 1)
                let vibrato = 1 + 0.007 * ease * sinf(DSP.twoPi * 5.5 * seconds)
                let rate = dt * vibrato
                phaseA = DSP.wrap(phaseA + rate - dt)
                let attack = min(seconds * 33, 1)
                let raw = DSP.saw(phaseA, rate) + 0.06 * noiseLeft.next()
                filterA.set(cutoff: min(baseHz * (3 + 3 * env2), 9_000), resonance: 0.25, sampleRate: sr)
                let body = filterA.process(raw).low
                let voiced = body * 0.55 + filterB.process(body).band * 0.9 + filterC.process(body).band * 0.6
                y = DSP.softClip(voiced * 1.2) * attack * 0.17
            case 9:
                // Soft piano: the fundamental with a slightly detuned twin (warmth), a second and third partial that
                // fade faster, and a felt hammer thump; a 25 ms attack and a lowpass that keeps it mellow.
                env3 *= mul3
                phaseB = DSP.wrap(phaseB + dt * 2.001)
                phaseC = DSP.wrap(phaseC + dt * 3.003)
                phaseD = DSP.wrap(phaseD + dt * 1.0015)
                let attack = min(seconds * 40, 1)
                let tone =
                    sinf(DSP.twoPi * phaseA) * 0.6 + sinf(DSP.twoPi * phaseD) * 0.4 + 0.3 * env2
                    * sinf(DSP.twoPi * phaseB) + 0.08 * env2 * sinf(DSP.twoPi * phaseC)
                let hammer = filterA.process(noiseLeft.next()).low * env3 * 0.4
                y = (tone * attack + hammer) * env1 * 0.24
            default:
                // Pad: two detuned saws, a slow attack and a gently moving lowpass.
                phaseB = DSP.wrap(phaseB + dt * 1.006)
                let attack = min(seconds * 4, 1)
                let raw = DSP.saw(phaseA, dt) + DSP.saw(phaseB, dt * 1.006)
                filterA.set(cutoff: 900 + 450 * sinf(DSP.twoPi * 0.3 * seconds), resonance: 0.2, sampleRate: sr)
                y = filterA.process(raw).low * attack * 0.11
            }
            y *= env5
            outLeft = y * left
            outRight = y * right

        case .blip:
            if holdCounter == 0 {
                phaseA = DSP.wrap(phaseA + baseHz * 6 * c.invSampleRate)
                held = (phaseA < 0.5 ? 1 : -1) * (1 - p)
                held = (held * 4).rounded() / 4
            }
            holdCounter = (holdCounter + 1) % 6
            let y = held * 0.3
            outLeft = y * left
            outRight = y * right
        }

        age += 1
        var gain = tail * velocity
        if fading {
            fade -= c.stealFadeStep
            if fade <= 0 {
                active = false
                return (0, 0)
            }
            gain *= fade
        }
        if age >= length { active = false }
        return (outLeft * gain, outRight * gain)
    }
}
