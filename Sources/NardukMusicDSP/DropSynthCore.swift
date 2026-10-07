import Foundation
import NardukMusicCore
import Synchronization

/// The three mixer buses of the drop synth.
public enum SynthBus: Int, Sendable, CaseIterable {
    case drums = 0
    case bass = 1
    case fx = 2
}

/// Control values the main actor hands the render thread each buffer (read from atomics).
struct RenderControls {
    var gains: (Float, Float, Float)
    var masterVolume: Float
    var fadingOut: Bool
    var bpmMilli: Int
}

/// Everything the render thread mutates. Lives behind one raw pointer owned by
/// `DropSynthCore`, so the render loop runs without exclusivity checks, ARC or allocation.
struct SynthState {
    static let kickCount = 2
    static let snareCount = 3
    static let hatCount = 4
    static let fxCount = 16
    static let stringCount = 24  // guitar strings; a strum takes six
    static let padCount = 8
    static let pendingCapacity = 2_048
    static let historySize = 1 << 18  // master history for stutter / tape stop (~5.4 s at 48 kHz)
    static let analysisSize = 1 << 13  // mono analysis ring

    let c: SynthCoefficients
    let stepsPerBar: Int
    var clock: StepClock
    var sampleClock = 0

    // Scheduling
    let pending: UnsafeMutablePointer<SynthEvent>
    var pendingCount = 0
    var nextDue = Int.max
    var droppedEvents = 0

    // Voices
    let kicks: UnsafeMutablePointer<KickVoice>
    var nextKick = 0
    let snares: UnsafeMutablePointer<SnareVoice>
    var nextSnare = 0
    let hats: UnsafeMutablePointer<HatVoice>
    var nextHat = 0
    let fx: UnsafeMutablePointer<FXVoice>
    var nextFX = 0
    let strings: UnsafeMutablePointer<StringVoice>
    var nextString = 0
    var stringsLive = 0
    var wobble = WobbleVoice()
    var sub = SubVoice()
    var reverb: RoomReverb

    // Ambient chain: pooled pads and drones into a long hall and a delay. Idle (and bit-for-bit silent in the mix)
    // until a pad note arrives; `ambientTail` counts the samples it keeps running after the last one.
    let pads: UnsafeMutablePointer<PadVoice>
    var nextPad = 0
    var hall: HallReverb
    var echo: StereoDelay
    var ambientTail = 0
    var space = AmbientSpace()

    // Sidechain
    var sidechain: Float = 0
    var sidechainAttacking = false

    // Mixer
    var busGains: (Float, Float, Float) = (1, 1, 1)
    var masterGain: Float = 0.8
    var stopGain: Float = 1
    let stopStep: Float

    // Master effects
    let historyLeft: UnsafeMutablePointer<Float>
    let historyRight: UnsafeMutablePointer<Float>
    var historyWrite = 0
    var stutterRemaining = 0
    var stutterLength = 0
    var stutterSlice = 1
    var stutterStart = 0
    var stutterAge = 0
    var tapeRemaining = 0
    var tapeLength = 0
    var tapeRead: Double = 0
    var tapeReturn = 0
    var limiter: BrickwallLimiter

    // Analysis / telemetry
    let analysis: UnsafeMutablePointer<Float>
    var analysisWritten = 0
    var hits: UInt32 = 0

    init(sampleRate: Double, bpm: Double, stepsPerBar: Int) {
        c = SynthCoefficients(sampleRate: sampleRate)
        self.stepsPerBar = max(stepsPerBar, 1)
        clock = StepClock(sampleRate: Int(sampleRate.rounded()), bpm: bpm)
        pending = .allocate(capacity: SynthState.pendingCapacity)
        kicks = .allocate(capacity: SynthState.kickCount)
        kicks.initialize(repeating: KickVoice(), count: SynthState.kickCount)
        snares = .allocate(capacity: SynthState.snareCount)
        for i in 0..<SynthState.snareCount {
            (snares + i).initialize(to: SnareVoice(seed: 0x2545_F491 &+ UInt32(i) &* 7_919))
        }
        hats = .allocate(capacity: SynthState.hatCount)
        for i in 0..<SynthState.hatCount {
            (hats + i).initialize(to: HatVoice(seed: 0x6C07_8965 &+ UInt32(i) &* 104_729))
        }
        fx = .allocate(capacity: SynthState.fxCount)
        for i in 0..<SynthState.fxCount {
            (fx + i).initialize(to: FXVoice(seed: 0x1F12_3BB5 &+ UInt32(i) &* 15_485_863))
        }
        reverb = RoomReverb(sampleRate: sampleRate)
        strings = .allocate(capacity: SynthState.stringCount)
        for i in 0..<SynthState.stringCount {
            (strings + i).initialize(to: StringVoice(seed: 0x9E37_79B9 &+ UInt32(i) &* 40_503))
        }
        pads = .allocate(capacity: SynthState.padCount)
        pads.initialize(repeating: PadVoice(), count: SynthState.padCount)
        hall = HallReverb(sampleRate: sampleRate)
        echo = StereoDelay(sampleRate: sampleRate)
        stopStep = 1 / Float(0.03 * sampleRate)
        historyLeft = .allocate(capacity: SynthState.historySize)
        historyLeft.initialize(repeating: 0, count: SynthState.historySize)
        historyRight = .allocate(capacity: SynthState.historySize)
        historyRight.initialize(repeating: 0, count: SynthState.historySize)
        limiter = BrickwallLimiter(sampleRate: sampleRate)
        analysis = .allocate(capacity: SynthState.analysisSize)
        analysis.initialize(repeating: 0, count: SynthState.analysisSize)
    }

    func deallocate() {
        pending.deallocate()
        kicks.deallocate()
        snares.deallocate()
        hats.deallocate()
        fx.deallocate()
        reverb.deallocate()
        for i in 0..<SynthState.stringCount { strings[i].deallocate() }
        strings.deallocate()
        pads.deallocate()
        hall.deallocate()
        echo.deallocate()
        historyLeft.deallocate()
        historyRight.deallocate()
        limiter.deallocate()
        analysis.deallocate()
    }

    // MARK: Scheduling

    mutating func enqueue(_ event: SynthEvent) {
        if event.instrument == Instrument.strum.synthCode || event.instrument == Instrument.electricStrum.synthCode {
            enqueueStrum(event)
            return
        }
        guard pendingCount < SynthState.pendingCapacity else {
            droppedEvents += 1
            return
        }
        pending[pendingCount] = event
        pendingCount += 1
    }

    /// Expands a strum into its six strings: the chord's voicing, one string at a time, each a little after the last
    /// (12 ms on a downstroke, 8 ms and lighter on an upstroke), the lead string reporting the hit.
    mutating func enqueueStrum(_ event: SynthEvent) {
        let electric = event.instrument == Instrument.electricStrum.synthCode
        let up = event.formant >= 0.5
        let intervals = StrumChord(voice: Int(max(event.voice, 0))).intervals
        var root = event.pitch < 0 ? 45 : event.pitch
        while root < 40 { root += 12 }
        while root >= 52 { root -= 12 }
        let stagger = Int((up ? 0.008 : 0.012) * Double(c.sampleRate))
        for sweep in 0..<intervals.count {
            let string = up ? intervals.count - 1 - sweep : sweep
            let reach = Float(string) / Float(intervals.count - 1)
            var e = event
            e.instrument = (electric ? Instrument.electricGuitar : Instrument.acousticGuitar).synthCode
            e.pitch = root + Float(intervals[string])
            e.velocity = event.velocity * (up ? 0.62 + 0.38 * reach : 1 - 0.28 * reach)
            e.pan = min(max(event.pan + (Float(string) - 2.5) * 0.06, -1), 1)
            e.voice = -1
            e.offset = Int32(sweep * stagger)
            e.flags = SynthEvent.StrumFlags.string
            if sweep == 0 { e.flags |= SynthEvent.StrumFlags.lead }
            if electric { e.flags |= SynthEvent.StrumFlags.electric }
            enqueue(e)
        }
    }

    /// The sample an event fires on: its step, plus any swing delay and sample offset.
    @inline(__always) func dueSample(_ event: SynthEvent) -> Int {
        let s = clock.sample(forStep: event.step)
        let swung = event.delay > 0 ? s + Int(Double(event.delay) * clock.samplesPerStep) : s
        return event.offset > 0 ? swung + Int(event.offset) : swung
    }

    mutating func recomputeNextDue() {
        var due = Int.max
        for i in 0..<pendingCount {
            let s = dueSample(pending[i])
            if s < due { due = s }
        }
        nextDue = due
    }

    /// Fires every pending event due at or before the current sample.
    mutating func fireDueEvents() {
        let late = Int(clock.samplesPerStep)
        var i = 0
        var due = Int.max
        while i < pendingCount {
            let event = pending[i]
            let s = dueSample(event)
            if s <= sampleClock {
                if sampleClock - s <= late { trigger(event) } else { droppedEvents += 1 }
                pendingCount -= 1
                pending[i] = pending[pendingCount]
            } else {
                if s < due { due = s }
                i += 1
            }
        }
        nextDue = due
    }

    mutating func gateSamples(_ event: SynthEvent) -> Int {
        clock.sample(forStep: event.step + Int(event.lengthSteps)) - clock.sample(forStep: event.step)
    }

    mutating func trigger(_ e: SynthEvent) {
        let velocity = e.velocity
        switch e.instrument {
        case 0:  // kick
            kicks[nextKick].steal()
            nextKick = (nextKick + 1) % SynthState.kickCount
            kicks[nextKick].trigger(velocity: velocity, c)
            sidechainAttacking = true
        case 1:  // snare
            // Round-robin so roll tails overlap naturally.
            nextSnare = (nextSnare + 1) % SynthState.snareCount
            snares[nextSnare].trigger(velocity: velocity, c)
        case 2, 3:  // hat, openHat
            let open = e.instrument == 3
            if !open {
                for i in 0..<SynthState.hatCount where hats[i].active && hats[i].isOpen { hats[i].steal() }
            }
            nextHat = (nextHat + 1) % SynthState.hatCount
            hats[nextHat].trigger(open: open, velocity: velocity * (open ? 0.85 : 0.7), pan: e.pan + 0.15, c)
        case 4:  // wobble
            wobble.noteOn(
                pitch: e.pitch, gateSamples: gateSamples(e), cyclesPerBeat: e.cyclesPerBeat,
                bpm: Float(clock.bpm), formant: e.formant, drive: e.drive, voice: Int(max(e.voice, 0)),
                velocity: velocity, pan: e.pan, glide: e.glide, c)
        case 5:  // sub
            sub.noteOn(pitch: e.pitch, gateSamples: gateSamples(e), velocity: velocity, glide: e.glide, c)
        case 6:  // glitch: master stutter + a crushed blip
            startFX(.blip, e)
            stutterSlice = max(Int(clock.samplesPerStep / 2), 64)
            stutterLength = max(gateSamples(e), stutterSlice)
            stutterRemaining = stutterLength
            stutterAge = 0
            stutterStart = historyWrite - stutterSlice
        case 7: startFX(.scratch, e)
        case 8: startFX(.laser, e)
        case 9: startFX(.vox, e)
        case 10:  // riser (at least 4 steps)
            var riser = e
            riser.lengthSteps = max(riser.lengthSteps, 4)
            startFX(.riser, riser)
        case 11:  // tape stop over lengthSteps (at most 2 bars)
            tapeLength = max(min(gateSamples(e), Int(clock.samplesPerStep * 32)), 256)
            tapeRemaining = tapeLength
            tapeRead = Double(historyWrite - 1)
            tapeReturn = 0
        case 12: startFX(.impact, e)
        case 13:
            if let kind = AmbientKind(voice: Int(e.voice)) { startPad(kind, e) } else { startFX(.keys, e) }
        case 14, 15, 16:  // acoustic, electric, bass guitar (a strum's strings arrive as the first two)
            startString(StringKind(rawValue: e.instrument - 14) ?? .acoustic, e)
        default: return  // 17, 18 (strums) were expanded into strings when queued
        }
        if e.flags & SynthEvent.StrumFlags.string == 0 {
            hits |= 1 << UInt32(e.instrument)
        } else if e.flags & SynthEvent.StrumFlags.lead != 0 {
            let strum = e.flags & SynthEvent.StrumFlags.electric != 0 ? Instrument.electricStrum : .strum
            hits |= 1 << UInt32(strum.synthCode)
        }
    }

    mutating func startString(_ kind: StringKind, _ e: SynthEvent) {
        // A free string if there is one; otherwise the oldest takes the new note (a click only past 24 strings).
        var slot = -1
        var oldest = 0
        var oldestAge = -1
        for i in 0..<SynthState.stringCount {
            if !strings[i].active {
                slot = i
                break
            }
            if strings[i].age > oldestAge {
                oldestAge = strings[i].age
                oldest = i
            }
        }
        if slot < 0 { slot = oldest }
        strings[slot].trigger(
            kind, pitch: e.pitch, velocity: e.velocity, gateSamples: gateSamples(e), pan: e.pan, drive: e.drive, c)
        stringsLive += 1
    }

    mutating func startPad(_ kind: AmbientKind, _ e: SynthEvent) {
        var slot = -1
        for i in 0..<SynthState.padCount where !pads[i].active {
            slot = i
            break
        }
        if slot < 0 {
            slot = nextPad
            nextPad = (nextPad + 1) % SynthState.padCount
            pads[slot].steal()
        }
        let gate = gateSamples(e)
        pads[slot].noteOn(kind, pitch: e.pitch, gateSamples: gate, velocity: e.velocity, c)
        // Keep the chain running through the note, its release and the hall's tail.
        let run =
            gate + PadVoice.releaseSamples(kind, sampleRate: c.sampleRate)
            + Int(space.reverbSeconds * 1.2 * c.sampleRate)
        ambientTail = max(ambientTail, run)
    }

    mutating func startFX(_ kind: FXKind, _ e: SynthEvent) {
        // Prefer a free voice; otherwise steal the next one round-robin.
        var slot = -1
        for i in 0..<SynthState.fxCount where !fx[i].active {
            slot = i
            break
        }
        if slot < 0 {
            slot = nextFX
            nextFX = (nextFX + 1) % SynthState.fxCount
        }
        fx[slot].trigger(
            kind, pitch: e.pitch, lengthSamples: gateSamples(e), velocity: e.velocity, pan: e.pan, voice: Int(e.voice),
            c)
    }

    // MARK: Render

    @inline(__always) mutating func historySample(_ buffer: UnsafeMutablePointer<Float>, at position: Double) -> Float {
        let mask = SynthState.historySize - 1
        let base = Int(position.rounded(.down))
        let frac = Float(position - Double(base))
        let a = buffer[base & mask]
        let b = buffer[(base + 1) & mask]
        return a + (b - a) * frac
    }

    mutating func render(
        frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
        controls: RenderControls
    ) {
        clock.advance(to: sampleClock)
        if controls.bpmMilli != clock.targetBpmMilli {
            clock.requestTempo(milli: controls.bpmMilli, currentSample: sampleClock, stepsPerBar: stepsPerBar)
        }
        recomputeNextDue()
        hall.setDecayIfChanged(space.reverbSeconds)
        echo.feedback = space.delayFeedback
        echo.setTime(steps: Double(space.delaySteps), bpm: clock.bpm, sampleRate: Double(c.sampleRate))

        let historyMask = SynthState.historySize - 1
        let analysisMask = SynthState.analysisSize - 1
        let smoothing = c.smoothing

        for frame in 0..<frames {
            if sampleClock >= nextDue { fireDueEvents() }

            // Sidechain envelope: fast attack on each kick, ~150 ms release.
            if sidechainAttacking {
                sidechain = 1 + (sidechain - 1) * c.sidechainAttack
                if sidechain > 0.97 { sidechainAttacking = false }
            } else {
                sidechain *= c.sidechainRelease
            }

            // Drums
            var drumsL: Float = 0
            var drumsR: Float = 0
            for i in 0..<SynthState.kickCount {
                let k = kicks[i].next(c)
                drumsL += k
                drumsR += k
            }
            var snareSum: Float = 0
            for i in 0..<SynthState.snareCount { snareSum += snares[i].next(c) }
            let room = reverb.process(snareSum)
            drumsL += snareSum * 0.8 + room.0 * 0.9
            drumsR += snareSum * 0.8 + room.1 * 0.9
            for i in 0..<SynthState.hatCount {
                let h = hats[i].next(c)
                drumsL += h.0 * 0.5
                drumsR += h.1 * 0.5
            }

            // Bass (ducked hard by the kick)
            let w = wobble.next(c)
            let s = sub.next(c) * 0.5
            let bassDuck = 1 - 0.85 * sidechain
            var bassL = (w.0 * 0.9 + s) * bassDuck
            var bassR = (w.1 * 0.9 + s) * bassDuck

            // FX (ducked gently)
            var fxL: Float = 0
            var fxR: Float = 0
            for i in 0..<SynthState.fxCount {
                let f = fx[i].next(c)
                fxL += f.0
                fxR += f.1
            }
            // Guitar strings share the existing buses (the bass guitar the bass bus, every other string the FX bus), and
            // are only touched while one is sounding, so a song without them renders bit for bit as it did before.
            if stringsLive > 0 {
                var guitarL: Float = 0
                var guitarR: Float = 0
                var bassGuitarL: Float = 0
                var bassGuitarR: Float = 0
                var live = 0
                for i in 0..<SynthState.stringCount where strings[i].active {
                    let g = strings[i].next(c)
                    if strings[i].kind == .bass {
                        bassGuitarL += g.0
                        bassGuitarR += g.1
                    } else {
                        guitarL += g.0
                        guitarR += g.1
                    }
                    if strings[i].active { live += 1 }
                }
                stringsLive = live
                bassL += bassGuitarL * bassDuck
                bassR += bassGuitarR * bassDuck
                fxL += guitarL
                fxR += guitarR
            }
            let fxDuck = 1 - 0.5 * sidechain
            fxL *= fxDuck
            fxR *= fxDuck

            if ambientTail > 0 {
                ambientTail -= 1
                var padL: Float = 0
                var padR: Float = 0
                for i in 0..<SynthState.padCount {
                    let p = pads[i].next(c)
                    padL += p.0
                    padR += p.1
                }
                padL *= space.padLevel
                padR *= space.padLevel
                let tail = hall.process(padL * space.reverbMix, padR * space.reverbMix)
                let echoes = echo.process(padL * space.delayMix, padR * space.delayMix)
                fxL += padL + tail.0 * 2.2 + echoes.0 * 1.2
                fxR += padR + tail.1 * 2.2 + echoes.1 * 1.2
            }

            busGains.0 = controls.gains.0 + (busGains.0 - controls.gains.0) * smoothing
            busGains.1 = controls.gains.1 + (busGains.1 - controls.gains.1) * smoothing
            busGains.2 = controls.gains.2 + (busGains.2 - controls.gains.2) * smoothing
            var mixL = drumsL * busGains.0 + bassL * busGains.1 + fxL * busGains.2 * 0.8
            var mixR = drumsR * busGains.0 + bassR * busGains.1 + fxR * busGains.2 * 0.8

            // Master history (feeds the stutter and the tape stop).
            historyLeft[historyWrite & historyMask] = mixL
            historyRight[historyWrite & historyMask] = mixR

            if tapeRemaining > 0 {
                let p = 1 - Float(tapeRemaining) / Float(tapeLength)
                let speed = Double(max(1 - p, 0))
                tapeRead += speed
                let fadeOut = p > 0.85 ? max((1 - p) / 0.15, 0) : 1
                mixL = historySample(historyLeft, at: tapeRead) * fadeOut
                mixR = historySample(historyRight, at: tapeRead) * fadeOut
                tapeRemaining -= 1
                if tapeRemaining == 0 { tapeReturn = 1 }
            } else if tapeReturn > 0 {
                // Clean return: fade the live signal back in over ~5 ms.
                let ramp = min(Float(tapeReturn) * c.invSampleRate * 200, 1)
                mixL *= ramp
                mixR *= ramp
                tapeReturn = ramp >= 1 ? 0 : tapeReturn + 1
            } else if stutterRemaining > 0 {
                let position = stutterAge % stutterSlice
                let index = (stutterStart + position) & historyMask
                let edge = Float(min(position, stutterSlice - position)) / 96
                let window = min(edge, 1)
                let crushL = (historyLeft[index] * 24).rounded() / 24
                let crushR = (historyRight[index] * 24).rounded() / 24
                let entry = min(Float(stutterAge) / 96, 1)
                let exit = min(Float(stutterRemaining) / 96, 1)
                let blend = min(entry, exit)
                mixL = mixL * (1 - blend) + crushL * window * blend
                mixR = mixR * (1 - blend) + crushR * window * blend
                stutterAge += 1
                stutterRemaining -= 1
            }
            historyWrite += 1

            // Soft saturation into the brickwall limiter.
            let satL = DSP.softClip(mixL * 0.72) * 1.32
            let satR = DSP.softClip(mixR * 0.72) * 1.32
            let limited = limiter.process(satL, satR)

            if controls.fadingOut {
                stopGain = max(stopGain - stopStep, 0)
            }
            masterGain = controls.masterVolume + (masterGain - controls.masterVolume) * smoothing
            let out = masterGain * stopGain
            let outL = limited.0 * out
            let outR = limited.1 * out
            left[frame] = outL
            right[frame] = outR

            analysis[analysisWritten & analysisMask] = (outL + outR) * 0.5
            analysisWritten += 1
            sampleClock += 1
        }
    }
}

/// The real-time synth: owns all render state and the lock-free plumbing to the main actor.
///
/// Threading contract: `schedule`, the setters and the telemetry readers are called from one
/// producer thread (the main actor); `render` is called from one consumer (the audio render
/// thread, or a test). `render` never allocates, locks or touches reference counts.
public final class DropSynthCore: @unchecked Sendable {
    public let sampleRate: Double
    private let state: UnsafeMutablePointer<SynthState>
    private let events = SPSCRing<SynthEvent>(capacity: 4_096)

    // Main → render controls.
    private let drumsGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let bassGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let fxGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let muteMask = Atomic<UInt32>(0)
    private let masterVolumeBits = Atomic<UInt32>(Float(0.8).bitPattern)
    private let fadeOut = Atomic<Bool>(false)
    private let bpmMilli: Atomic<Int>
    // The ambient chain's settings: the bit patterns of an `AmbientSpace`'s six floats.
    private let spaceAtomics = AmbientSpaceAtomics()

    // Render → main telemetry.
    private let renderedSamples = Atomic<Int>(0)
    private let stepPositionBits = Atomic<UInt64>(Double(0).bitPattern)
    private let lastFrames = Atomic<Int>(0)
    private let hitsMask = Atomic<UInt32>(0)
    private let wobblePhaseBits = Atomic<UInt32>(0)
    private let wobbleCutoffBits = Atomic<UInt32>(0)
    private let analysisWritten = Atomic<Int>(0)
    private let limiterGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let droppedCount = Atomic<Int>(0)

    public init(sampleRate: Double, bpm: Double = 140, stepsPerBar: Int = 16) {
        self.sampleRate = sampleRate
        state = .allocate(capacity: 1)
        state.initialize(to: SynthState(sampleRate: sampleRate, bpm: bpm, stepsPerBar: stepsPerBar))
        bpmMilli = Atomic<Int>(StepClock.milliBPM(bpm))
    }

    deinit {
        state.pointee.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }

    // MARK: Producer side (main actor)

    /// Queues a note for sample-accurate playback. Returns false if the queue is full.
    @discardableResult
    public func schedule(_ note: ScheduledNote) -> Bool {
        events.push(SynthEvent(note))
    }

    /// Sets the tempo; the render thread applies it from the next bar boundary.
    public func setTempo(_ bpm: Double) {
        bpmMilli.store(StepClock.milliBPM(bpm), ordering: .relaxed)
    }

    /// Sets the ambient chain's reverb, delay and pad level (clamped to sane ranges); it applies from the next buffer.
    public func setAmbientSpace(_ space: AmbientSpace) {
        func store(_ value: Float, _ range: ClosedRange<Float>, _ atomic: borrowing Atomic<UInt32>) {
            let safe = min(max(value.isFinite ? value : range.lowerBound, range.lowerBound), range.upperBound)
            atomic.store(safe.bitPattern, ordering: .relaxed)
        }
        store(space.reverbSeconds, 0.1...HallReverb.maxDecaySeconds, spaceAtomics.reverbSeconds)
        store(space.reverbMix, 0...1, spaceAtomics.reverbMix)
        store(space.delayMix, 0...1, spaceAtomics.delayMix)
        store(space.delayFeedback, 0...0.95, spaceAtomics.delayFeedback)
        store(space.delaySteps, 0.25...64, spaceAtomics.delaySteps)
        store(space.padLevel, 0...1.5, spaceAtomics.padLevel)
    }

    public func setGain(_ gain: Float, for bus: SynthBus) {
        let value = min(max(gain.isFinite ? gain : 0, 0), 1.5).bitPattern
        switch bus {
        case .drums: drumsGainBits.store(value, ordering: .relaxed)
        case .bass: bassGainBits.store(value, ordering: .relaxed)
        case .fx: fxGainBits.store(value, ordering: .relaxed)
        }
    }

    public func setMuted(_ muted: Bool, for bus: SynthBus) {
        let bit = UInt32(1) << UInt32(bus.rawValue)
        if muted {
            muteMask.bitwiseOr(bit, ordering: .relaxed)
        } else {
            muteMask.bitwiseAnd(~bit, ordering: .relaxed)
        }
    }

    public func setMasterVolume(_ volume: Float) {
        masterVolumeBits.store(min(max(volume.isFinite ? volume : 0, 0), 1).bitPattern, ordering: .relaxed)
    }

    /// Ramps the output to silence over 30 ms (and keeps it silent).
    public func beginFadeOut() {
        fadeOut.store(true, ordering: .relaxed)
    }

    /// Step position at the end of the most recently rendered buffer (ahead of what is audible).
    public var renderedStepPosition: Double {
        Double(bitPattern: stepPositionBits.load(ordering: .acquiring))
    }

    public var renderedSampleCount: Int { renderedSamples.load(ordering: .acquiring) }

    /// Frames in the most recent render call.
    public var lastBufferFrames: Int { lastFrames.load(ordering: .relaxed) }

    /// Instruments triggered since the previous call.
    public func takeHits() -> Set<Instrument> {
        Instrument.set(fromMask: hitsMask.exchange(0, ordering: .acquiringAndReleasing))
    }

    public var wobblePhase: Float { Float(bitPattern: wobblePhaseBits.load(ordering: .relaxed)) }
    public var wobbleCutoff: Float { Float(bitPattern: wobbleCutoffBits.load(ordering: .relaxed)) }

    /// The lowest limiter gain over the most recent buffer (1 = no gain reduction).
    public var limiterGain: Float { Float(bitPattern: limiterGainBits.load(ordering: .relaxed)) }

    /// Events dropped because they arrived too late or the queues were full.
    public var droppedEvents: Int { droppedCount.load(ordering: .relaxed) }

    /// Samples of delay the master limiter adds.
    public var limiterLatency: Int { state.pointee.limiter.latency }

    /// Copies the most recent mono output samples into `destination` (oldest first).
    /// The render thread may be writing concurrently; a torn sample only affects a visual.
    public func copyRecentSamples(into destination: UnsafeMutableBufferPointer<Float>) {
        let written = analysisWritten.load(ordering: .acquiring)
        let count = min(destination.count, SynthState.analysisSize - 1024)
        let mask = SynthState.analysisSize - 1
        let ring = state.pointee.analysis
        for i in 0..<count {
            let index = written - count + i
            destination[i] = index >= 0 ? ring[index & mask] : 0
        }
        if destination.count > count {
            for i in count..<destination.count { destination[i] = 0 }
        }
    }

    // MARK: Consumer side (render thread)

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        let mutes = muteMask.load(ordering: .relaxed)
        let g0 = mutes & 1 != 0 ? 0 : Float(bitPattern: drumsGainBits.load(ordering: .relaxed))
        let g1 = mutes & 2 != 0 ? 0 : Float(bitPattern: bassGainBits.load(ordering: .relaxed))
        let g2 = mutes & 4 != 0 ? 0 : Float(bitPattern: fxGainBits.load(ordering: .relaxed))
        let controls = RenderControls(
            gains: (g0, g1, g2),
            masterVolume: Float(bitPattern: masterVolumeBits.load(ordering: .relaxed)),
            fadingOut: fadeOut.load(ordering: .relaxed),
            bpmMilli: bpmMilli.load(ordering: .relaxed)
        )
        while let event = events.pop() { state.pointee.enqueue(event) }
        state.pointee.space = AmbientSpace(
            reverbSeconds: Float(bitPattern: spaceAtomics.reverbSeconds.load(ordering: .relaxed)),
            reverbMix: Float(bitPattern: spaceAtomics.reverbMix.load(ordering: .relaxed)),
            delayMix: Float(bitPattern: spaceAtomics.delayMix.load(ordering: .relaxed)),
            delayFeedback: Float(bitPattern: spaceAtomics.delayFeedback.load(ordering: .relaxed)),
            delaySteps: Float(bitPattern: spaceAtomics.delaySteps.load(ordering: .relaxed)),
            padLevel: Float(bitPattern: spaceAtomics.padLevel.load(ordering: .relaxed)))
        state.pointee.render(frames: frames, left: left, right: right, controls: controls)

        let s = state
        if s.pointee.hits != 0 {
            hitsMask.bitwiseOr(s.pointee.hits, ordering: .releasing)
            s.pointee.hits = 0
        }
        wobblePhaseBits.store(s.pointee.wobble.lfoPhase.bitPattern, ordering: .relaxed)
        let cutoff: Float = s.pointee.wobble.active ? s.pointee.wobble.normalizedCutoff : 0
        wobbleCutoffBits.store(cutoff.bitPattern, ordering: .relaxed)
        limiterGainBits.store(s.pointee.limiter.takeMinimumGain().bitPattern, ordering: .relaxed)
        droppedCount.store(s.pointee.droppedEvents, ordering: .relaxed)
        lastFrames.store(frames, ordering: .relaxed)
        analysisWritten.store(s.pointee.analysisWritten, ordering: .releasing)
        let position = s.pointee.clock.stepPosition(atSample: s.pointee.sampleClock)
        stepPositionBits.store(position.bitPattern, ordering: .releasing)
        renderedSamples.store(s.pointee.sampleClock, ordering: .releasing)
    }
}

/// The atomics behind `DropSynthCore.setAmbientSpace(_:)` (a struct of named fields, since a tuple cannot hold them).
private struct AmbientSpaceAtomics: ~Copyable {
    let reverbSeconds = Atomic<UInt32>(AmbientSpace().reverbSeconds.bitPattern)
    let reverbMix = Atomic<UInt32>(AmbientSpace().reverbMix.bitPattern)
    let delayMix = Atomic<UInt32>(AmbientSpace().delayMix.bitPattern)
    let delayFeedback = Atomic<UInt32>(AmbientSpace().delayFeedback.bitPattern)
    let delaySteps = Atomic<UInt32>(AmbientSpace().delaySteps.bitPattern)
    let padLevel = Atomic<UInt32>(AmbientSpace().padLevel.bitPattern)
}
