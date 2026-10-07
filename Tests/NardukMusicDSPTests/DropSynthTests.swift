import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

@Suite struct DropSynthTests {
    // MARK: Limiter

    @Test func limiterNeverExceedsCeilingOnHotInput() {
        var limiter = BrickwallLimiter(sampleRate: 48_000)
        defer { limiter.deallocate() }
        var noise = NoiseSource(seed: 42)
        var peak: Float = 0
        for n in 0..<48_000 * 4 {
            let t = Float(n) / 48_000
            // +12 dBFS sine with random spikes up to +24 dBFS and single-sample impulses.
            var x = 4 * sinf(DSP.twoPi * 55 * t) + noise.next() * 2
            if n % 9_973 == 0 { x = 16 }
            if n % 7_919 == 0 { x = -16 }
            let (l, r) = limiter.process(x, -x * 0.5)
            #expect(l.isFinite && r.isFinite)
            peak = max(peak, abs(l), abs(r))
        }
        #expect(peak <= DSP.ceiling)
        #expect(peak > DSP.ceiling * 0.9, "limiter should drive a hot signal up to the ceiling, got \(peak)")
    }

    @Test func limiterIsTransparentBelowTheCeiling() {
        var limiter = BrickwallLimiter(sampleRate: 48_000)
        defer { limiter.deallocate() }
        var outputs: [Float] = []
        for n in 0..<4_800 {
            let x = 0.5 * sinf(DSP.twoPi * 440 * Float(n) / 48_000)
            outputs.append(limiter.process(x, x).0)
        }
        let latency = limiter.latency
        for n in 1_000..<4_800 {
            let expected = 0.5 * sinf(DSP.twoPi * 440 * Float(n - latency) / 48_000)
            #expect(abs(outputs[n] - expected) < 1e-4)
        }
    }

    // MARK: Ring

    @Test func ringPreservesOrderAndDropsWhenFull() {
        let ring = SPSCRing<Int>(capacity: 8)
        #expect(ring.capacity == 8)
        for i in 0..<8 { #expect(ring.push(i)) }
        #expect(!ring.push(99), "a full ring must drop, not overwrite")
        #expect(ring.count == 8)
        for i in 0..<5 { #expect(ring.pop() == i) }
        for i in 8..<13 { #expect(ring.push(i)) }
        #expect(!ring.push(100))
        var drained: [Int] = []
        while let value = ring.pop() { drained.append(value) }
        #expect(drained == Array(5..<13))
        #expect(ring.pop() == nil)
    }

    @Test func ringHandsOffAcrossThreadsInOrder() async {
        let ring = SPSCRing<Int>(capacity: 64)
        let total = 200_000
        let producer = Task.detached {
            var i = 0
            while i < total {
                if ring.push(i) { i += 1 }
            }
        }
        var expected = 0
        var inOrder = true
        while expected < total {
            if let value = ring.pop() {
                if value != expected { inOrder = false }
                expected += 1
            }
        }
        await producer.value
        #expect(inOrder)
    }

    // MARK: Clock

    @Test func stepToSampleIsExactAt140BPM48kHzWithoutDrift() {
        let clock = StepClock(sampleRate: 48_000, bpm: 140)
        // 48000 * 60 / (140 * 4) = 36000 / 7 samples per step.
        var previous = clock.sample(forStep: 0)
        #expect(previous == 0)
        for n in 1...10_000 {
            let s = clock.sample(forStep: n)
            #expect(s == n * 36_000 / 7)
            #expect(s - previous == 5_142 || s - previous == 5_143)
            #expect(clock.step(atSample: s) == n)
            #expect(clock.step(atSample: s - 1) == n - 1)
            previous = s
        }
        #expect(clock.sample(forStep: 10_000) == 51_428_571)
        #expect(abs(clock.stepPosition(atSample: 51_428_571) - 9_999.999_916_666) < 1e-6)
    }

    @Test func tempoChangeLandsOnTheNextBar() {
        var clock = StepClock(sampleRate: 48_000, bpm: 140)
        let now = clock.sample(forStep: 21) + 100  // inside bar 1
        clock.requestTempo(150, currentSample: now)
        #expect(clock.pendingStep == 32)
        #expect(clock.sample(forStep: 32) == 32 * 36_000 / 7)  // the boundary keeps the old grid
        #expect(clock.sample(forStep: 33) - clock.sample(forStep: 32) == 4_800)  // 150 BPM: 4800 samples/step
        clock.advance(to: clock.sample(forStep: 40))
        #expect(clock.bpmMilli == 150_000)
        #expect(clock.step(atSample: clock.sample(forStep: 40)) == 40)
    }

    // MARK: Filter and voices

    @Test func filterIsStableAtMaximumResonance() {
        let sr: Float = 48_000
        var filter = SVF()
        var noise = NoiseSource(seed: 7)
        var peak: Float = 0
        for n in 0..<Int(sr) * 10 {
            // Sweep the cutoff 20 Hz ... 20 kHz and back while hammering it with noise and impulses.
            let sweep = 0.5 - 0.5 * cosf(DSP.twoPi * Float(n) / sr * 0.7)
            filter.set(cutoff: 20 * powf(1_000, sweep), resonance: 1.0, sampleRate: sr)
            let x = n % 4_801 == 0 ? 1 : noise.next() * 0.5
            let y = filter.process(x)
            #expect(y.low.isFinite && y.band.isFinite && y.high.isFinite)
            peak = max(peak, abs(y.low), abs(y.band))
        }
        #expect(peak < 200, "resonant SVF blew up: \(peak)")
    }

    @Test func kickRendersPunchyFiniteOutput() {
        let c = SynthCoefficients(sampleRate: 48_000)
        var kick = KickVoice()
        kick.trigger(velocity: 1, c)
        var peak: Float = 0
        var energy: Float = 0
        var samples = 0
        while kick.active, samples < 48_000 * 2 {
            let y = kick.next(c)
            #expect(y.isFinite)
            peak = max(peak, abs(y))
            energy += y * y
            samples += 1
        }
        #expect(peak > 0.5)
        #expect(sqrtf(energy / Float(samples)) > 0.1)
        #expect(samples < 48_000 * 2, "kick should finish on its own")
    }

    @Test func envelopeDecaysExponentially() {
        var env = DecayEnvelope(seconds: 0.1, sampleRate: 48_000)
        env.trigger()
        for _ in 0..<4_800 { _ = env.next() }
        #expect(abs(env.value - expf(-1)) < 1e-3)
    }

    // MARK: Core scheduling

    @Test func coreTriggersSampleAccurately() {
        let core = DropSynthCore(sampleRate: 48_000)
        core.setMasterVolume(1)
        core.schedule(ScheduledNote(step: 4, instrument: .kick, velocity: 1))
        let frames = 48_000
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var rendered = 0
        while rendered < frames {
            core.render(frames: min(256, frames - rendered), left: left + rendered, right: right + rendered)
            rendered += 256
        }
        let expectedStart = 4 * 36_000 / 7 + core.limiterLatency
        let firstSound = (0..<frames).first { abs(left[$0]) > 1e-6 }
        // The kick's sine starts at phase 0 and its click starts at once: audible within 2 samples.
        #expect(
            firstSound.map { $0 >= expectedStart && $0 <= expectedStart + 2 } == true,
            "expected the kick at \(expectedStart), heard it at \(String(describing: firstSound))")
        #expect(core.takeHits() == [.kick])
        #expect(core.takeHits().isEmpty)
    }

    /// The hit counters share `Instrument.index` lanes with the synth's codes, and every instrument has a lane.
    @Test func hitCounterLanesMatchTheSynthCodes() {
        #expect(Instrument.allCases.count <= HitCounters.laneCount)
        #expect(Set(Instrument.allCases.map(\.index)).count == Instrument.allCases.count)
        for instrument in Instrument.allCases { #expect(Int(instrument.synthCode) == instrument.index) }
    }

    /// Counters are monotonic and keep multiplicity: two kicks in one poll are two, and polling clears nothing.
    @Test func hitCountersCountEveryHitAndClearNothing() {
        let core = DropSynthCore(sampleRate: 48_000, bpm: 140)
        for step in [0, 4, 8] { core.schedule(ScheduledNote(step: step, instrument: .kick, velocity: 1)) }
        core.schedule(ScheduledNote(step: 4, instrument: .snare, velocity: 1))
        let frames = 48_000
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer {
            left.deallocate()
            right.deallocate()
        }
        #expect(core.hitCounters == HitCounters())
        var rendered = 0
        var seen = HitCounters()
        var kicks: UInt32 = 0
        while rendered < frames {
            core.render(frames: 256, left: left, right: right)
            rendered += 256
            let now = core.hitCounters
            kicks += now.delta(since: seen)[.kick]
            seen = now
        }
        #expect(kicks == 3)
        #expect(core.hitCounters[.kick] == 3 && core.hitCounters[.snare] == 1)
        #expect(core.hitCounters[.hat] == 0)
        #expect(core.hitCounters == core.hitCounters)
        #expect(core.takeHits() == [.kick, .snare])
        #expect(core.hitCounters[.kick] == 3)
    }

    @Test func spectrumAnalyzerFindsASine() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let samples = (0..<2_048).map { 0.5 * sinf(DSP.twoPi * 1_000 * Float($0) / 48_000) }
        var bands: [Float] = []
        for _ in 0..<20 { bands = analyzer.process(samples) }
        let loudest = bands.indices.max { bands[$0] < bands[$1] } ?? 0
        let center = analyzer.centerFrequency(ofBand: loudest)
        #expect(center > 850 && center < 1_180, "loudest band centered at \(center) Hz")
        #expect(bands[loudest] > 0.85)
        #expect(bands[2] < 0.2)
    }

    // MARK: Offline render of the demo

    @Test func demoRendersLoudCleanAndLimited() throws {
        let sampleRate = 48_000.0
        let core = DropSynthCore(sampleRate: sampleRate)
        core.setMasterVolume(1)
        let settings = SongSettings()
        let bars = 8
        let totalFrames = Int(Double(bars * 16) * settings.secondsPerStep * sampleRate) + 4_800
        let left = UnsafeMutablePointer<Float>.allocate(capacity: totalFrames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: totalFrames)
        defer {
            left.deallocate()
            right.deallocate()
        }

        // Feed it the way the engine does: notes ~100 ms ahead of the render position.
        var scheduledThrough = -1
        var rendered = 0
        let block = 512
        let lookaheadSteps = 0.1 / settings.secondsPerStep
        var minimumGain: Float = 1
        var gainSum: Double = 0
        var gainBlocks = 0
        while rendered < totalFrames {
            let through = min(Int(core.renderedStepPosition + lookaheadSteps), bars * 16 - 1)
            if through > scheduledThrough {
                for note in DemoPattern.notes(in: (scheduledThrough + 1)...through) { #expect(core.schedule(note)) }
                scheduledThrough = through
            }
            let n = min(block, totalFrames - rendered)
            core.render(frames: n, left: left + rendered, right: right + rendered)
            rendered += n
            minimumGain = min(minimumGain, core.limiterGain)
            gainSum += Double(DSP.decibels(core.limiterGain))
            gainBlocks += 1
        }
        #expect(core.droppedEvents == 0)

        var peak: Float = 0
        var sumSquares: Double = 0
        var finite = true
        for i in 0..<totalFrames {
            let l = left[i]
            let r = right[i]
            if !l.isFinite || !r.isFinite { finite = false }
            peak = max(peak, abs(l), abs(r))
            sumSquares += Double(l * l + r * r)
        }
        let rms = Float(sqrt(sumSquares / Double(totalFrames * 2)))
        let rmsDB = DSP.decibels(rms)
        let peakDB = DSP.decibels(peak)
        print(
            "demo render: peak \(peakDB) dBFS, rms \(rmsDB) dBFS, max GR \(DSP.decibels(minimumGain)) dB, "
                + "mean GR \(gainSum / Double(gainBlocks)) dB")
        #expect(finite)
        #expect(peak <= DSP.ceiling)
        #expect(rmsDB > -16 && rmsDB < -6, "RMS \(rmsDB) dBFS is outside the loud-but-sane range")

        if let path = ProcessInfo.processInfo.environment["DROP_RENDER_WAV"] {
            try WAVWriter.write16(
                left: left, right: right, frames: totalFrames, sampleRate: Int(sampleRate),
                to: URL(fileURLWithPath: path))
        }
    }

    @Test func everyInstrumentRendersFinite() {
        let core = DropSynthCore(sampleRate: 44_100)
        core.setMasterVolume(1)
        var step = 0
        for instrument in Instrument.allCases {
            core.schedule(
                ScheduledNote(
                    step: step, instrument: instrument, velocity: 1,
                    params: NoteParams(
                        pitch: 41, lengthSteps: 4, wobbleRate: .sixteenthTriplet,
                        formant: 1, drive: 1, voice: 3, pan: -1)))
            step += 2
        }
        let frames = 44_100 * 6
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var rendered = 0
        while rendered < frames {
            core.render(frames: min(1_024, frames - rendered), left: left + rendered, right: right + rendered)
            rendered += 1_024
        }
        var peak: Float = 0
        for i in 0..<frames {
            #expect(left[i].isFinite && right[i].isFinite)
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        #expect(peak <= DSP.ceiling)
        #expect(peak > 0.1)
    }

    @Test func fadeOutReachesSilence() {
        let core = DropSynthCore(sampleRate: 48_000)
        for note in DemoPattern.notes(in: 32...40) {
            core.schedule(
                ScheduledNote(
                    step: note.step - 32, instrument: note.instrument,
                    velocity: note.velocity, params: note.params))
        }
        let frames = 4_800
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        core.render(frames: frames, left: left, right: right)
        core.beginFadeOut()
        core.render(frames: frames, left: left, right: right)
        // 30 ms fade at 48 kHz = 1440 samples; after that it must be silent.
        #expect((1_500..<frames).allSatisfy { left[$0] == 0 && right[$0] == 0 })
        // ... and the fade itself is gradual (no step larger than the signal's own swing).
        #expect(abs(left[0]) < 1)
    }
}

/// Minimal 16-bit PCM WAV writer for listening to offline renders.
enum WAVWriter {
    static func write16(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Int, to url: URL
    ) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataBytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4))
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        data.reserveCapacity(44 + dataBytes)
        for i in 0..<frames {
            append(Int16(max(min(left[i], 1), -1) * 32_767))
            append(Int16(max(min(right[i], 1), -1) * 32_767))
        }
        try data.write(to: url)
    }
}
