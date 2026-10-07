import Foundation
import NardukMusicCore

extension SampleSource {
    /// A window onto an `InstrumentBank` clip: loops `loopStart ..< loopEnd` when the clip has a loop.
    init(instruments bank: InstrumentBank, clip: Int) {
        let c = bank.clips[clip]
        self.init()
        self.bank = bank.pcm
        offset = c.offset
        count = c.count
        loopStart = c.loopStart
        loopEnd = max(c.loopEnd, 1)
        looping = c.loopEnd > c.loopStart + 8
    }
}

/// One recorded instrument note (`InstrumentBank`): the clip read at the rate that pitches it to the note, with
/// Hermite interpolation. Not the singer's voice: an instrument has its own envelope and dynamics.
///
/// - A sustained note (flute, sax) fades in over 15 ms (the recording carries its own attack), holds on its loop for
///   the gate and releases.
/// - A plucked or struck note (piano, steel drum, guitar) starts at once, rings out on the recording, and is damped
///   over the instrument's release when its gate ends.
/// - A percussion hit plays whole; only a steal cuts it short.
///
/// Level follows velocity on a power law with no floor (a soft hit is soft), times the instrument's trim. Plain value
/// state over the bank's shared memory: triggering and rendering never allocate.
struct InstrumentVoice: @unchecked Sendable {
    private(set) var active = false
    private(set) var instrument = SampledInstrument.piano
    private var source = SampleSource()
    private var position = 0.0
    private var rate = 1.0
    private var gain: Float = 0
    private var panL: Float = 0.7071
    private var panR: Float = 0.7071
    private var gateLeft = 0
    private var envelope: Float = 0
    private var attackStep: Float = 1
    private var releaseStep: Float = 0
    private var stealStep: Float = 0
    private(set) var age = 0

    /// Whether this voice is hand percussion (it joins the drums, not the melodic sum).
    var isPercussion: Bool { instrument.isPercussion }

    /// Starts `clip` of `bank`. `rate` is source samples per output sample.
    mutating func trigger(
        _ instrument: SampledInstrument, bank: InstrumentBank, clip: Int, rate: Double, gateSamples: Int,
        velocity: Float, pan: Float, engineRate: Float, timbre: TimbrePatch = .neutral
    ) {
        self.instrument = instrument
        source = SampleSource(instruments: bank, clip: clip)
        position = 0
        self.rate = rate
        let v = min(max(velocity, 0), 1)
        gain = (instrument.isPercussion ? powf(v, 1.5) : powf(v, 1.2)) * instrument.trim
        let angle = (min(max(pan, -1), 1) + 1) * Float.pi / 4
        panL = cosf(angle)
        panR = sinf(angle)
        // A percussion hit has no gate: it plays to the end of its recording.
        gateLeft = instrument.isPercussion ? Int.max : max(gateSamples, 1)
        // A track's timbre (`TimbrePatch`) stretches the sustained attack and every release; a recording's tone is
        // its own.
        let attack: Float = instrument.sustains ? 0.015 * min(max(timbre.attack, 0.5), 2) : 0.0005
        attackStep = 1 / max(attack * engineRate, 1)
        let release = instrument.releaseSeconds * timbre.decay
        releaseStep = release > 0 ? 1 / max(release * engineRate, 1) : 0
        envelope = 0
        stealStep = 0
        age = 0
        active = true
    }

    /// Fades out over 5 ms at most (its gate ended, so it never swells back) so a new note can take the slot, or the
    /// tail slot can finish it, without a click.
    mutating func steal(engineRate: Float) {
        stealStep = 1 / max(0.005 * engineRate, 1)
        gateLeft = 0
    }

    mutating func next() -> (Float, Float) {
        guard active else { return (0, 0) }
        age += 1
        let s = source.interpolate(position)
        position += rate
        if !source.looping && position >= Double(source.count - 1) { active = false }
        if gateLeft > 0 {
            if gateLeft != Int.max { gateLeft -= 1 }
            envelope = min(envelope + attackStep, 1)
        } else {
            envelope -= releaseStep
            if envelope <= 0 { active = false }
        }
        if stealStep > 0 {
            envelope -= stealStep
            if envelope <= 0 { active = false }
        }
        let out = s * gain * max(envelope, 0)
        return (out * panL, out * panR)
    }
}
