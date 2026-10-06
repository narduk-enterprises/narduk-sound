import Foundation

/// Which way a strum sweeps across the strings.
public enum StrumStroke: String, Sendable, Hashable, Codable, CaseIterable {
    /// Low string to high string, the heavier stroke.
    case down
    /// High string to low string, quicker and lighter (`NoteParams.formant` of 0.5 or more).
    case up
}

/// The chords a strum can play: a fixed set of six-string voicings built on a root, until the conductor writes its
/// own. `NoteParams.voice` picks one (`voice % count`, in the order of `allCases`).
public enum StrumChord: String, Sendable, Hashable, Codable, CaseIterable {
    case major, minor, dominant7, minor7, power, sus2

    /// Semitones above the root, low string to high string (six strings, the root on the lowest).
    public var intervals: [Int] {
        switch self {
        case .major: [0, 7, 12, 16, 19, 24]
        case .minor: [0, 7, 12, 15, 19, 24]
        case .dominant7: [0, 7, 10, 16, 19, 24]
        case .minor7: [0, 7, 10, 15, 19, 22]
        case .power: [0, 7, 12, 19, 24, 31]
        case .sus2: [0, 7, 12, 14, 19, 24]
        }
    }

    /// The `NoteParams.voice` value that picks this chord.
    public var voice: Int { StrumChord.allCases.firstIndex(of: self) ?? 0 }

    public init(voice: Int) {
        let all = StrumChord.allCases
        self = all[((voice % all.count) + all.count) % all.count]
    }
}

/// Which plucked instrument a `StringVoice` is playing; each is a patch over the same Karplus-Strong string.
public enum StringKind: UInt8, Sendable, Hashable, BitwiseCopyable {
    case acoustic, electric, bass
}

/// The sound of one plucked instrument: how the string is struck and how it rings. A value built by a switch, so
/// picking one on the render thread never allocates.
struct StringPatch: Sendable, Hashable, BitwiseCopyable {
    /// Where the string is plucked, as a fraction of its length (a comb on the excitation: nearer the bridge is thinner).
    var pickPosition: Float
    /// The lowest and highest MIDI note the instrument plays; a note outside is folded in by octaves.
    var lowest: Float
    var highest: Float
    /// Seconds for the string to fall 60 dB at the reference pitch (MIDI 55), before the loop filter's own loss.
    var sustain: Float
    /// How much longer (+) or shorter (-) low notes ring, in octaves of decay time per octave of pitch.
    var sustainSlope: Float
    /// Loop filter openness at velocity 0 and 1 (0.5 is the darkest string, 1 is no loss): a harder pluck rings brighter.
    var brightnessSoft: Float
    var brightnessHard: Float
    /// Excitation lowpass cutoff in Hz at velocity 0 and 1.
    var excitationSoft: Float
    var excitationHard: Float
    /// Seconds the string rings on after the key is let go.
    var damping: Float
    /// Output level at velocity 1.
    var level: Float

    static func patch(for kind: StringKind) -> StringPatch {
        switch kind {
        case .acoustic:
            StringPatch(
                pickPosition: 0.17, lowest: 40, highest: 88, sustain: 2.6, sustainSlope: -0.35,
                brightnessSoft: 0.62, brightnessHard: 0.85, excitationSoft: 2_600, excitationHard: 9_000,
                damping: 0.09, level: 0.5)
        case .electric:
            StringPatch(
                pickPosition: 0.11, lowest: 40, highest: 88, sustain: 4.2, sustainSlope: -0.25,
                brightnessSoft: 0.7, brightnessHard: 0.92, excitationSoft: 3_200, excitationHard: 10_000,
                damping: 0.14, level: 0.5)
        case .bass:
            StringPatch(
                pickPosition: 0.26, lowest: 28, highest: 60, sustain: 2.2, sustainSlope: -0.2,
                brightnessSoft: 0.55, brightnessHard: 0.72, excitationSoft: 900, excitationHard: 2_600,
                damping: 0.07, level: 0.62)
        }
    }
}

/// A Karplus-Strong plucked string: a delay line one period long, fed back through a loss filter, tuned to the
/// note with an allpass, and excited by a burst of filtered noise. The acoustic guitar adds a body resonance, the
/// electric guitar drive and a cabinet-shaped filter, and the bass a dark, round output stage.
///
/// The delay line is allocated when the voice is built, fixed at 8,192 samples: room for the lowest bass note
/// (E1, 41 Hz) at 192 kHz, which needs about 4,700. `trigger` and `next` allocate nothing. Excitation comes from the
/// voice's own seeded noise source, so an offline render is deterministic.
public struct StringVoice {
    public private(set) var active = false
    public private(set) var isFading = false
    public private(set) var age = 0
    public private(set) var kind: StringKind = .acoustic

    // The string.
    private let line: UnsafeMutablePointer<Float>
    private let mask: Int
    private var write = 0
    private var length = 2  // whole samples of delay in the loop
    private var previous: Float = 0  // loop filter memory
    private var brightness: Float = 0.7  // loop filter weight of the new sample
    private var loopGain: Float = 0.99
    private var allpassCoefficient: Float = 0
    private var allpassIn: Float = 0
    private var allpassOut: Float = 0

    // The note.
    private var noise: NoiseSource
    private var gateEnd = 0
    private var lifeEnd = 0
    private var releasing = false
    private var release: Float = 0.999
    private var rampIn: Float = 0
    private var rampStep: Float = 0.01
    private var fade: Float = 1
    private var gain: Float = 1
    private var left: Float = 0.707
    private var right: Float = 0.707
    private var drive: Float = 0

    // The output stage.
    private var dc = OnePole()
    private var bodyLow = SVF()
    private var bodyHigh = SVF()
    private var cabLow = SVF()
    private var cabPresence = SVF()
    private var cabHighpass = OnePole()
    private var bassLow = OnePole()

    public static let lineCapacity = 8_192

    public init(seed: UInt32 = 0x9E37_79B9) {
        line = .allocate(capacity: StringVoice.lineCapacity)
        line.initialize(repeating: 0, count: StringVoice.lineCapacity)
        mask = StringVoice.lineCapacity - 1
        noise = NoiseSource(seed: seed)
    }

    public mutating func deallocate() {
        line.deallocate()
    }

    /// Starts a note. `pitch` is MIDI, `gateSamples` how long the key is held, `drive` 0 ... 1 (< 0 for the default).
    public mutating func trigger(
        _ kind: StringKind, pitch notePitch: Float, velocity noteVelocity: Float, gateSamples: Int, pan: Float,
        drive noteDrive: Float, _ c: SynthCoefficients
    ) {
        let patch = StringPatch.patch(for: kind)
        self.kind = kind
        let sr = c.sampleRate
        let velocity = min(max(noteVelocity, 0), 1)

        // Fold the pitch into the instrument's range, and keep the loop long enough to be a delay line.
        var pitch = notePitch.isFinite ? notePitch : 60
        while pitch < patch.lowest { pitch += 12 }
        while pitch > patch.highest { pitch -= 12 }
        let frequency = min(max(DSP.midiToHz(pitch), 25), sr / 4)

        // Loop filter: a weighted two-point average. Its group delay at low frequency is (1 - weight) samples.
        let hardness = velocity
        brightness = patch.brightnessSoft + (patch.brightnessHard - patch.brightnessSoft) * hardness
        let filterDelay = 1 - brightness
        // The rest of the period is whole samples plus an allpass for the fraction.
        let needed = sr / frequency - filterDelay
        length = min(max(Int(needed - 0.5), 2), mask - 4)
        let fraction = needed - Float(length)
        allpassCoefficient = (1 - fraction) / (1 + fraction)
        allpassIn = 0
        allpassOut = 0
        previous = 0

        // Loop gain: the string falls 60 dB in `sustain` seconds at MIDI 55, longer or shorter by pitch.
        let octaves = (pitch - 55) / 12
        let seconds = max(patch.sustain * exp2f(patch.sustainSlope * octaves), 0.15)
        loopGain = expf(-6.907_755 / (seconds * frequency))
        lifeEnd = Int(seconds * 1.1 * sr)

        // Excitation: filtered noise with the pick-position comb, centered, scaled to the note's level.
        let cutoff = patch.excitationSoft + (patch.excitationHard - patch.excitationSoft) * hardness
        var pluckFilter = OnePole(cutoff: cutoff, sampleRate: sr)
        let span = length + 1
        var mean: Float = 0
        for i in 0..<span {
            let sample = pluckFilter.lowpass(noise.next())
            line[i] = sample
            mean += sample
        }
        mean /= Float(span)
        let pick = min(max(Int(Float(span) * patch.pickPosition), 1), span - 1)
        var peak: Float = 1e-6
        var i = span - 1
        while i >= 0 {
            let value = line[i] - mean - (i >= pick ? line[i - pick] - mean : 0)
            line[i] = value
            peak = max(peak, abs(value))
            i -= 1
        }
        let scale = (0.35 + 0.65 * velocity) / peak
        for j in 0..<span { line[j] *= scale }
        write = span

        // Output stage and envelope.
        gateEnd = max(gateSamples, Int(0.02 * sr))
        releasing = false
        release = DSP.decay(seconds: patch.damping, sampleRate: sr)
        rampIn = 0
        rampStep = 1 / (0.0007 * sr)
        fade = 1
        gain = patch.level
        age = 0
        isFading = false
        active = true
        (left, right) = DSP.pan(pan)
        drive = kind == .electric ? (noteDrive < 0 ? 0.45 : min(noteDrive, 1)) : (kind == .bass ? 0.15 : 0)

        dc.setCutoff(28, sampleRate: sr)
        dc.z = 0
        bodyLow.reset()
        bodyHigh.reset()
        cabLow.reset()
        cabPresence.reset()
        cabHighpass.z = 0
        bassLow.z = 0
        switch kind {
        case .acoustic:
            bodyLow.set(cutoff: 105, resonance: 0.9, sampleRate: sr)  // the top plate's main resonance
            bodyHigh.set(cutoff: 215, resonance: 0.85, sampleRate: sr)  // the air cavity
        case .electric:
            cabLow.set(cutoff: 4_800, resonance: 0.35, sampleRate: sr)
            cabPresence.set(cutoff: 2_300, resonance: 0.55, sampleRate: sr)
            cabHighpass.setCutoff(85, sampleRate: sr)
        case .bass:
            bassLow.setCutoff(1_900, sampleRate: sr)
        }
    }

    public mutating func steal() {
        if active { isFading = true }
    }

    @inline(__always) public mutating func next(_ c: SynthCoefficients) -> (Float, Float) {
        guard active else { return (0, 0) }

        // The string.
        let tap = line[(write - length) & mask]
        let filtered = brightness * tap + (1 - brightness) * previous
        previous = tap
        let tuned = allpassCoefficient * filtered + allpassIn - allpassCoefficient * allpassOut
        allpassIn = filtered
        allpassOut = tuned + DSP.antiDenormal
        let fed = tuned * loopGain
        line[write & mask] = fed
        write += 1
        let string = dc.highpass(fed)

        // The output stage.
        var out: Float
        switch kind {
        case .acoustic:
            let low = bodyLow.process(string).band
            let high = bodyHigh.process(string).band
            out = string * 0.85 + low * 0.55 + high * 0.4
        case .electric:
            let driven = DSP.softClip(string * (1.2 + drive * 7)) / (1 + drive * 0.9)
            let cab = cabLow.process(driven).low + cabPresence.process(driven).band * 0.35
            out = cabHighpass.highpass(cab)
        case .bass:
            let round = bassLow.lowpass(string)
            out = DSP.softClip(round * (1 + drive * 2)) / (1 + drive * 0.6)
        }

        // Envelope: a short ramp in, the key held, then damped; stolen voices fade out.
        age += 1
        if rampIn < 1 { rampIn = min(rampIn + rampStep, 1) }
        if !releasing, age >= gateEnd || age >= lifeEnd { releasing = true }
        if releasing {
            gain *= release
            if gain < 2e-4 { active = false }
        }
        if isFading {
            fade -= c.stealFadeStep
            if fade <= 0 {
                fade = 0
                active = false
            }
        }
        out *= gain * rampIn * fade
        return (out * left, out * right)
    }
}
