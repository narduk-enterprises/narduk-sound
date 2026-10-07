import Foundation
import NardukMusicCore

/// One recorded clip as the voice reads it: a window onto the bank's immutable PCM, with Catmull-Rom interpolation and
/// the sustain's loop wrap. Plain value over shared memory, so reading never allocates.
struct SampleSource: @unchecked Sendable {
    var bank: UnsafeMutablePointer<Float>?
    var offset = 0
    var count = 1
    var loopStart = 0
    var loopEnd = 1
    var looping = false

    init() {}

    init(bank samples: SampleBank, clip: Int) {
        let c = samples.clips[clip]
        bank = samples.pcm
        offset = c.offset
        count = c.count
        loopStart = c.loopStart
        loopEnd = c.loopEnd
        looping = c.kind == .sustain
    }

    @inline(__always) func read(_ i: Int) -> Float {
        guard let bank else { return 0 }
        var j = i
        if looping && j >= loopEnd { j = loopStart + (j - loopEnd) % (loopEnd - loopStart) }
        return bank[offset + min(max(j, 0), count - 1)]
    }

    @inline(__always) func interpolate(_ position: Double) -> Float {
        let i = Int(position)
        let t = Float(position - Double(i))
        let p0 = read(i - 1)
        let p1 = read(i)
        let p2 = read(i + 1)
        let p3 = read(i + 2)
        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
        let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * p2
        return ((a * t + b) * t + c) * t + p1
    }
}

/// One windowed slice of the recording, for the granular modes.
private struct Grain: Sendable {
    var active = false
    var center = 0.0
    var centerB = 0.0
    var age = 0
    var length = 1
}

/// How a voice reads its clip.
private enum ReadMode: UInt8 {
    /// One read head, resampled to the note (the original path).
    case plain
    /// Grains emitted at the note's own period, each reading the voice at a shifted rate: the pitch is exactly the note
    /// and the formants move (formant shift, autotune snap).
    case coherent
    /// Grains emitted at a fixed rate, the read head crawling or frozen: time-stretch and freeze.
    case texture
}

/// One sampled singer: reads a clip from the `SampleBank` at a rate that pitches it to the note (a sustain loops
/// between its loop points until the gate ends; a chop or a run plays once), with Hermite interpolation, a short attack
/// and a release. A note with a `VocalExpression` also gets pitch automation (vibrato, scoop, bend, detune), a vowel
/// morph across the note, a granular re-singing (formant shift, snap, stretch, freeze), breath, grit and a filter, and
/// reports how much of it to send to the echo and the room. No allocation: plain value state over the bank's memory.
struct SampleVoice: @unchecked Sendable {
    private(set) var active = false
    private var a = SampleSource()
    private var b = SampleSource()
    private var position = 0.0
    private var positionB = 0.0
    private var rate = 1.0
    private var rateB = 1.0
    private var sourcePeriodB = 100.0
    private var centerOriginB = 0.0
    private var gain: Float = 0
    private var panL: Float = 0.7071
    private var panR: Float = 0.7071
    private var gateLeft = 0
    private var gateTotal = 1
    private var envelope: Float = 0
    private var attackStep: Float = 0.01
    private var releaseStep: Float = 0.001
    private var stealStep: Float = 0
    private(set) var age = 0

    // Expression (all inert while `expressed` is false).
    private var expressed = false
    private var engineRate: Float = 48_000
    private var mode = ReadMode.plain
    private var morphing = false
    private var vibratoDepth: Float = 0
    private var vibratoPhase: Float = 0
    private var vibratoStep: Float = 0
    private var scoopNow: Float = 0
    private var scoopDecay: Float = 1
    private var bendSemitones: Float = 0
    private var bendStart = 0
    private var bendSpan = 1
    private var detuneSemitones: Float = 0
    private var rateScale: Float = 1
    private var rateTarget: Float = 1
    private var control = 0
    private var reverse = false
    private var swell: Float = 0
    private var breath: Float = 0
    private var grit: Float = 0
    private var noise: UInt32 = 0x1234_5678
    private var breathFilter = OnePole()
    private var chainA = SVF()
    private var chainB = SVF()
    private var chainKind = VocalFilter.none
    private var frozen = false
    private var timeScale = 0.0

    // Granular state.
    private var grains: (Grain, Grain, Grain, Grain, Grain, Grain) = (
        Grain(), Grain(), Grain(), Grain(), Grain(), Grain()
    )
    private var center = 0.0
    private var centerOrigin = 0.0
    private var spawnIn = 0.0
    private var hop = 1.0
    private var grainLength = 64
    private var grainRate = 1.0
    private var grainNorm: Float = 1
    private var noteHz = 440.0
    private var sourcePeriod = 100.0  // source samples per cycle of the recording
    private var sourceRatio = 1.0  // bank sample rate over engine rate
    private var bankRate = 22_050.0
    private var jitter: UInt32 = 0x2545_F491

    /// How much of this voice goes to the vocal echo (0 ... 1) and how many sixteenth steps its repeats are apart.
    private(set) var echoSend: Float = 0
    private(set) var echoSteps: Double = 6
    /// Extra room send: a fraction of the voice, blooming across the note.
    private(set) var roomSend: Float = 0

    /// Starts `clip` for `gateSamples`. `rate` is source samples per output sample (pitch and sample-rate ratio).
    /// `expression` (non-nil and not plain) turns on the processing, `morphClip` is the second vowel's clip.
    mutating func trigger(
        bank samples: SampleBank, clip: Int, rate: Double, gateSamples: Int, velocity: Float, gain trim: Float,
        pan: Float, engineRate sampleRate: Float, expression: VocalExpression? = nil, morphClip: Int = -1,
        morphRate: Double = 1, notePitch: Float = 69, seed: UInt32 = 1
    ) {
        let c = samples.clips[clip]
        bankRate = samples.sampleRate
        a = SampleSource(bank: samples, clip: clip)
        b = morphClip >= 0 ? SampleSource(bank: samples, clip: morphClip) : SampleSource()
        position = 0
        positionB = 0
        self.rate = rate
        rateB = morphRate
        gain = (0.35 + 0.65 * velocity) * trim * 1.6
        let angle = (min(max(pan, -1), 1) + 1) * Float.pi / 4
        panL = cosf(angle)
        panR = sinf(angle)
        gateLeft = max(gateSamples, 1)
        gateTotal = gateLeft
        envelope = 0
        let attack: Float = c.kind == .sustain ? 0.03 : (c.kind == .chop ? 0.002 : 0.004)
        let release: Float = c.kind == .sustain ? 0.14 : (c.kind == .chop ? 0.03 : 0.05)
        attackStep = 1 / max(attack * sampleRate, 1)
        releaseStep = 1 / max(release * sampleRate, 1)
        stealStep = 0
        age = 0
        expressed = false
        echoSend = 0
        roomSend = 0
        active = true
        if let expression, !expression.isPlain {
            express(
                expression, clip: c, morph: morphClip >= 0 ? samples.clips[morphClip] : nil, rate: rate,
                engineRate: sampleRate, pitch: notePitch, seed: seed)
        }
    }

    private mutating func express(
        _ x: VocalExpression, clip c: SampleBank.Clip, morph: SampleBank.Clip?, rate: Double,
        engineRate sampleRate: Float,
        pitch: Float, seed: UInt32
    ) {
        expressed = true
        engineRate = sampleRate
        let sustain = c.kind == .sustain
        morphing = morph != nil && sustain
        if let morph {
            sourcePeriodB = bankRate / (440 * pow(2, Double(morph.root - 69) / 12))
            centerOriginB = Double(morph.loopStart)
        }
        reverse = x.reverse
        // A reverse swell ends on the downbeat: a short release, so the swell is cut where the next phrase begins.
        if reverse { releaseStep = 1 / max(0.012 * sampleRate, 1) }
        swell = Float(x.swell)
        breath = Float(x.breath) * 0.5
        grit = Float(x.grit)
        noise = seed &* 2_654_435_761 | 1
        breathFilter.setCutoff(2_400, sampleRate: sampleRate)

        // Pitch automation.
        let snapped = x.snap && sustain
        vibratoDepth = snapped ? 0 : Float(x.vibratoDepth) * 0.7
        vibratoStep = 2 * .pi * (4 + 4 * Float(x.vibratoRate)) / sampleRate
        vibratoPhase = Float(seed & 255) / 255 * 2 * .pi
        scoopNow = Float(x.scoop)
        let arrive = 0.03 + 0.22 * Float(x.scoopTime)
        scoopDecay = expf(-3 / (arrive * sampleRate))
        bendSemitones = Float(x.bend)
        bendSpan = max(Int(Float(x.bendSpan) * Float(gateTotal)), 1)
        bendStart = gateTotal - bendSpan
        detuneSemitones = Float(x.detune) / 100
        rateScale = 1
        rateTarget = 1
        control = 0

        // Grains: formant shift and snap re-sing a sustain at the note's own pitch; stretch re-reads any clip.
        sourceRatio = bankRate / Double(sampleRate)
        if x.stretch > 0 {
            mode = .texture
            timeScale = [1, 0.25, 0.1, 0][min(x.stretch, 3)]
            frozen = x.stretch == 3
            hop = Double(sampleRate) * 0.013
            grainLength = max(Int(hop * 4), 64)
            grainNorm = 0.5
            center = sustain ? Double(c.loopStart + (c.loopEnd - c.loopStart) / 2) : 0
        } else if sustain && (x.snap || x.formantShift != 0) {
            mode = .coherent
            timeScale = 1
            frozen = false
            noteHz = 440 * pow(2, Double(pitch - 69) / 12)
            sourcePeriod = bankRate / (440 * pow(2, Double(c.root - 69) / 12))
            grainRate = sourceRatio * pow(2, Double(x.formantShift) / 16)
            center = Double(c.loopStart)
            centerOrigin = center
        } else {
            mode = .plain
        }
        grains = (Grain(), Grain(), Grain(), Grain(), Grain(), Grain())
        spawnIn = 0
        jitter = seed &* 747_796_405 | 1
        if mode != .plain { updateGrainTiming() }

        // Filter.
        chainKind = x.filter
        switch x.filter {
        case .none: break
        case .telephone:
            chainA.set(cutoff: 1_300, resonance: 0.55, sampleRate: sampleRate)
            chainB.set(cutoff: 3_300, resonance: 0.1, sampleRate: sampleRate)
        case .radio:
            chainA.set(cutoff: 320, resonance: 0.15, sampleRate: sampleRate)
            chainB.set(cutoff: 5_200, resonance: 0.2, sampleRate: sampleRate)
        case .muffled:
            chainA.set(cutoff: 850, resonance: 0.1, sampleRate: sampleRate)
            chainB.set(cutoff: 1_500, resonance: 0.1, sampleRate: sampleRate)
        }
        chainA.reset()
        chainB.reset()
        echoSend = x.echo == .off ? 0 : Float(x.echoSend)
        echoSteps = x.echo.steps
    }

    /// Grain spacing and length from the note's pitch now.
    private mutating func updateGrainTiming() {
        switch mode {
        case .coherent:
            let fOut = max(noteHz * Double(rateScale), 20)
            hop = Double(engineRate) / fOut
            grainLength = min(max(Int(2 * sourcePeriod / grainRate), 32), 4_096)
            // Never more grains alive than slots.
            if Double(grainLength) > hop * 5.5 { grainLength = Int(hop * 5.5) }
            grainNorm = min(max(Float(2 * hop / Double(grainLength)), 0.3), 2)
        case .texture:
            grainRate = rate * Double(rateScale)
        case .plain: break
        }
    }

    /// Fades out quickly so a new note can take the slot without a click.
    mutating func steal(engineRate: Float) { stealStep = 1 / max(0.004 * engineRate, 1) }

    private mutating func nextRandom() -> UInt32 {
        noise ^= noise << 13
        noise ^= noise >> 17
        noise ^= noise << 5
        return noise
    }

    private mutating func spawnGrain() {
        var newGrain = Grain(active: true, center: center, centerB: center, age: 0, length: grainLength)
        if mode == .coherent {
            // Grains start a whole number of the recording's cycles apart, so they overlap in phase and the output
            // repeats exactly at the grain spacing: the note's pitch.
            let cycles = ((center - centerOrigin) / sourcePeriod).rounded()
            newGrain.center = centerOrigin + cycles * sourcePeriod
            if morphing {
                // The second vowel keeps its own cycle: its grains start whole cycles of it apart.
                let offset = center - centerOrigin
                newGrain.centerB = centerOriginB + (offset / sourcePeriodB).rounded() * sourcePeriodB
                if b.looping, newGrain.centerB >= Double(b.loopEnd) {
                    newGrain.centerB =
                        centerOriginB
                        + (newGrain.centerB - Double(b.loopEnd))
                        .truncatingRemainder(dividingBy: Double(b.loopEnd - b.loopStart))
                }
            }
        }
        if mode == .texture {
            // A little scatter of the read head so a frozen note shimmers instead of buzzing.
            jitter ^= jitter << 13
            jitter ^= jitter >> 17
            jitter ^= jitter << 5
            let spread = Double(Int32(bitPattern: jitter)) / 2_147_483_648
            newGrain.center += spread * 0.004 * Double(engineRate) * sourceRatio
        }
        withUnsafeMutablePointer(to: &grains) {
            $0.withMemoryRebound(to: Grain.self, capacity: 6) { g in
                var slot = 0
                var oldest = -1
                for i in 0..<6 {
                    if !g[i].active {
                        slot = i
                        oldest = Int.max
                        break
                    }
                    if g[i].age > oldest {
                        oldest = g[i].age
                        slot = i
                    }
                }
                g[slot] = newGrain
            }
        }
    }

    private mutating func grainSample() -> Float {
        spawnIn -= 1
        if spawnIn <= 0 {
            spawnGrain()
            spawnIn += hop
        }
        var sum: Float = 0
        let rate = grainRate
        let src = a
        let srcB = b
        let morphMix = morphing ? min(max(Float(age) / Float(gateTotal), 0), 1) : 0
        let mixA = cosf(morphMix * .pi / 2)
        let mixB = sinf(morphMix * .pi / 2)
        withUnsafeMutablePointer(to: &grains) {
            $0.withMemoryRebound(to: Grain.self, capacity: 6) { g in
                for i in 0..<6 where g[i].active {
                    let phase = Float(g[i].age) / Float(g[i].length)
                    let w = 0.5 - 0.5 * cosf(2 * .pi * phase)
                    let at = g[i].center + (Double(g[i].age) - Double(g[i].length) / 2) * rate
                    var s = src.interpolate(at)
                    if morphMix > 0 {
                        let atB = g[i].centerB + (Double(g[i].age) - Double(g[i].length) / 2) * rate
                        s = s * mixA + srcB.interpolate(atB) * mixB
                    }
                    sum += w * s
                    g[i].age += 1
                    if g[i].age >= g[i].length { g[i].active = false }
                }
            }
        }
        // The read head: natural speed (coherent), or the stretch's crawl (texture), looping on a sustain.
        if !frozen {
            center += (mode == .coherent ? sourceRatio : rate * timeScale)
            if src.looping {
                if center >= Double(src.loopEnd) { center -= Double(src.loopEnd - src.loopStart) }
            } else if center >= Double(src.count - 1) {
                center = Double(src.count - 1)
                if gateLeft > 0 && timeScale > 0 { gateLeft = min(gateLeft, 1) }
            }
        }
        return sum * grainNorm
    }

    mutating func next() -> (Float, Float) {
        guard active else { return (0, 0) }
        age += 1
        var s: Float
        if !expressed {
            s = a.interpolate(position)
            position += rate
            if a.looping {
                if position >= Double(a.loopEnd) { position -= Double(a.loopEnd - a.loopStart) }
            } else if position >= Double(a.count - 1) {
                active = false
            }
        } else {
            s = expressedSample()
        }
        if gateLeft > 0 {
            gateLeft -= 1
            envelope = min(envelope + attackStep, 1)
        } else {
            envelope -= releaseStep
        }
        if stealStep > 0 { envelope -= stealStep }
        if envelope <= 0 && gateLeft <= 0 { active = false }
        var level = max(envelope, 0)
        if expressed {
            let progress = min(Float(age) / Float(gateTotal), 1)
            if reverse && gateLeft > 0 { level *= progress * progress * progress }
            roomSend = swell * progress * progress * (gateLeft > 0 ? 1 : level)
            s = character(s, level: level)
        }
        let out = s * gain * level
        return (out * panL, out * panR)
    }

    private mutating func expressedSample() -> Float {
        // Pitch automation, recomputed every 32 samples and slewed between.
        control -= 1
        if control <= 0 {
            control = 32
            vibratoPhase += vibratoStep * 32
            if vibratoPhase > 2 * .pi { vibratoPhase -= 2 * .pi }
            // Vibrato fades in over a quarter second, so a scoop is not wobbled.
            let onset = min(Float(age) / (0.25 * engineRate), 1)
            var semitones = vibratoDepth * onset * sinf(vibratoPhase) + scoopNow + detuneSemitones
            if age > bendStart {
                let p = min(Float(age - bendStart) / Float(bendSpan), 1)
                semitones += bendSemitones * p * p
            }
            rateTarget = exp2f(semitones / 12)
            if reverse {
                let p = min(Float(age) / Float(gateTotal), 1)
                let cutoff = 500 + 9_000 * p * p
                chainA.set(cutoff: cutoff, resonance: 0.1, sampleRate: engineRate)
            }
            if mode != .plain { updateGrainTiming() }
        }
        scoopNow *= scoopDecay
        rateScale += (rateTarget - rateScale) * 0.04

        var s: Float
        switch mode {
        case .plain:
            let morphMix = morphing ? min(max(Float(age) / Float(gateTotal), 0), 1) : 0
            s = a.interpolate(position)
            if morphMix > 0 {
                s = s * cosf(morphMix * .pi / 2) + b.interpolate(positionB) * sinf(morphMix * .pi / 2)
            }
            position += rate * Double(rateScale)
            positionB += rateB * Double(rateScale)
            if a.looping {
                if position >= Double(a.loopEnd) { position -= Double(a.loopEnd - a.loopStart) }
                if b.looping, positionB >= Double(b.loopEnd) { positionB -= Double(b.loopEnd - b.loopStart) }
            } else if position >= Double(a.count - 1) {
                active = false
            }
        case .coherent, .texture:
            s = grainSample()
        }
        return s
    }

    /// Breath, grit and the filter, applied to the voice before its gain.
    private mutating func character(_ input: Float, level: Float) -> Float {
        var s = input
        if breath > 0 {
            let n = Float(Int32(bitPattern: nextRandom())) * (1 / 2_147_483_648)
            s += breathFilter.highpass(n) * breath * 0.4
        }
        if grit > 0 {
            let drive = 1 + 5 * grit
            s = tanhf(s * drive * 1.6) / (1.6 * sqrtf(drive))
        }
        if reverse {
            s = chainA.process(s).low
        } else {
            switch chainKind {
            case .none: break
            case .telephone:
                s = chainB.process(chainA.process(s).band * 1.9).low * 1.3
            case .radio:
                let high = chainA.process(s).high
                s = tanhf(chainB.process(high).low * 1.8) * 0.8
            case .muffled:
                s = chainB.process(chainA.process(s).low).low
            }
        }
        return s
    }
}
