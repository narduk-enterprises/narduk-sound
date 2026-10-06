import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The guitars (narduk-libs#1574): Karplus-Strong strings tuned by allpass, a six-string strum, and their place in
/// the synth. The no-allocation proof is in `RenderThreadAllocationTests`.
@Suite struct StringVoiceTests {
    static let sampleRate: Float = 48_000

    static func render(
        _ kind: StringKind, pitch: Float, velocity: Float = 0.8, gateSeconds: Float = 1, drive: Float = -1,
        seconds: Float = 1
    ) -> [Float] {
        let c = SynthCoefficients(sampleRate: Double(sampleRate))
        var voice = StringVoice(seed: 7)
        defer { voice.deallocate() }
        voice.trigger(
            kind, pitch: pitch, velocity: velocity, gateSamples: Int(gateSeconds * sampleRate), pan: 0, drive: drive, c)
        return (0..<Int(seconds * sampleRate)).map { _ in
            let s = voice.next(c)
            return (s.0 + s.1) * 0.5
        }
    }

    /// The fundamental by autocorrelation with parabolic interpolation around the strongest lag.
    static func frequency(_ x: [Float], expected: Float) -> Float {
        let start = 6_000
        let window = 8_192
        let low = Int(Self.sampleRate / expected * 0.9)
        let high = Int(Self.sampleRate / expected * 1.1)
        func r(_ lag: Int) -> Float {
            var sum: Float = 0
            for i in start..<(start + window) { sum += x[i] * x[i + lag] }
            return sum
        }
        var best = low
        var bestValue = -Float.infinity
        for lag in low...high {
            let v = r(lag)
            if v > bestValue {
                bestValue = v
                best = lag
            }
        }
        let a = r(best - 1)
        let b = r(best)
        let c = r(best + 1)
        let shift = 0.5 * (a - c) / (a - 2 * b + c)
        return Self.sampleRate / (Float(best) + shift)
    }

    static func cents(_ measured: Float, _ expected: Float) -> Float { 1_200 * log2f(measured / expected) }

    @Test(
        arguments: [
            (StringKind.acoustic, 40.0), (.acoustic, 52), (.acoustic, 64), (.acoustic, 76), (.electric, 45),
            (.electric, 57), (.electric, 69), (.bass, 28), (.bass, 33), (.bass, 40), (.bass, 52),
        ] as [(StringKind, Float)])
    func everyKindIsInTuneAcrossItsRange(kind: StringKind, pitch: Float) {
        let x = Self.render(kind, pitch: pitch, drive: 0.4, seconds: 0.8)
        let expected = DSP.midiToHz(pitch)
        let off = Self.cents(Self.frequency(x, expected: expected), expected)
        #expect(abs(off) < 8, "\(kind) at MIDI \(pitch) is \(off) cents off")
    }

    @Test func aNoteOutsideTheRangeFoldsByOctaves() {
        // MIDI 100 on a bass folds down to 52; MIDI 10 on a guitar folds up to 46.
        let high = Self.render(.bass, pitch: 100, seconds: 0.8)
        let bass = DSP.midiToHz(52)
        #expect(abs(Self.cents(Self.frequency(high, expected: bass), bass)) < 8)
        let low = Self.render(.acoustic, pitch: 10, seconds: 0.8)
        let guitar = DSP.midiToHz(46)
        #expect(abs(Self.cents(Self.frequency(low, expected: guitar), guitar)) < 8)
    }

    @Test func aHarderPluckIsLouderAndBrighter() {
        func energy(_ x: [Float]) -> (loud: Float, bright: Float) {
            var loud: Float = 0
            var bright: Float = 0
            for i in 1..<x.count {
                loud += x[i] * x[i]
                bright += (x[i] - x[i - 1]) * (x[i] - x[i - 1])
            }
            return (loud, bright / max(loud, 1e-9))
        }
        let soft = energy(Self.render(.acoustic, pitch: 57, velocity: 0.2, seconds: 0.5))
        let hard = energy(Self.render(.acoustic, pitch: 57, velocity: 1, seconds: 0.5))
        #expect(hard.loud > soft.loud * 2)
        #expect(hard.bright > soft.bright)
    }

    @Test func theInstrumentsDifferInCharacter() {
        func brightness(_ x: [Float]) -> Float {
            var loud: Float = 0
            var bright: Float = 0
            for i in 1..<x.count {
                loud += x[i] * x[i]
                bright += (x[i] - x[i - 1]) * (x[i] - x[i - 1])
            }
            return bright / max(loud, 1e-9)
        }
        let acoustic = brightness(Self.render(.acoustic, pitch: 52, seconds: 0.5))
        let electric = brightness(Self.render(.electric, pitch: 52, drive: 0.9, seconds: 0.5))
        let bass = brightness(Self.render(.bass, pitch: 52, seconds: 0.5))
        #expect(bass < acoustic, "a bass guitar should be darker than an acoustic: \(bass) vs \(acoustic)")
        #expect(electric > bass, "a driven electric should be brighter than a bass: \(electric) vs \(bass)")
    }

    @Test func driveShapesAnElectricGuitarAndBoundsIt() {
        let clean = Self.render(.electric, pitch: 52, drive: 0, seconds: 0.5)
        let hot = Self.render(.electric, pitch: 52, drive: 1, seconds: 0.5)
        func rms(_ x: [Float]) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(x.count)) }
        #expect(rms(hot) > rms(clean), "drive should raise the sustained level")
        #expect(hot.allSatisfy { $0.isFinite && abs($0) < 1.5 })
    }

    @Test func aStringRingsUntilTheKeyIsLetGoThenDamps() {
        let short = Self.render(.acoustic, pitch: 52, gateSeconds: 0.2, seconds: 1.6)
        let long = Self.render(.acoustic, pitch: 52, gateSeconds: 1.2, seconds: 1.6)
        func rms(_ x: [Float], _ from: Float, _ to: Float) -> Float {
            let slice = x[Int(from * Self.sampleRate)..<Int(to * Self.sampleRate)]
            return sqrtf(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
        }
        #expect(rms(short, 0.1, 0.2) > 0.01)
        #expect(rms(short, 0.7, 0.8) < rms(short, 0.1, 0.2) * 0.02, "a damped string must fall silent")
        #expect(rms(long, 0.7, 0.8) > rms(long, 0.1, 0.2) * 0.1, "a held string must still ring")
    }

    @Test func aDeadVoiceIsInactiveAndSilent() {
        let c = SynthCoefficients(sampleRate: Double(Self.sampleRate))
        var voice = StringVoice(seed: 3)
        defer { voice.deallocate() }
        voice.trigger(.bass, pitch: 40, velocity: 1, gateSamples: 2_000, pan: 0, drive: -1, c)
        var frames = 0
        while voice.active, frames < 48_000 * 10 {
            _ = voice.next(c)
            frames += 1
        }
        #expect(!voice.active, "a damped note must free its voice")
        #expect(voice.next(c) == (0, 0))
    }

    @Test func extremeInputsStayFiniteAndBounded() {
        for kind in [StringKind.acoustic, .electric, .bass] {
            for pitch: Float in [0, 12, 127, .nan, .infinity] {
                for velocity: Float in [0, 1, 7, -3] {
                    let x = Self.render(kind, pitch: pitch, velocity: velocity, drive: 1, seconds: 0.15)
                    #expect(x.allSatisfy { $0.isFinite && abs($0) < 2 }, "\(kind) pitch \(pitch) velocity \(velocity)")
                }
            }
        }
    }

    // MARK: The strum

    @Test func aStrumIsSixStaggeredStringsOnTheChord() {
        var state = SynthState(sampleRate: 48_000, bpm: 120, stepsPerBar: 16)
        defer { state.deallocate() }
        let note = ScheduledNote(
            step: 4, instrument: .strum, velocity: 0.8, params: NoteParams(pitch: 45, lengthSteps: 8, voice: 1))
        state.enqueue(SynthEvent(note))
        #expect(state.pendingCount == 6)
        let events = (0..<6).map { state.pending[$0] }
        #expect(events.map { Int($0.pitch) } == StrumChord.minor.intervals.map { 45 + $0 }, "A minor on an A root")
        #expect(events.allSatisfy { $0.instrument == Instrument.acousticGuitar.synthCode && $0.step == 4 })
        let offsets = events.map { Int($0.offset) }
        #expect(offsets[0] == 0 && zip(offsets, offsets.dropFirst()).allSatisfy { $1 - $0 == 576 }, "\(offsets)")
        #expect(events[0].flags & SynthEvent.StrumFlags.lead != 0)
        #expect(events.dropFirst().allSatisfy { $0.flags & SynthEvent.StrumFlags.lead == 0 })
        #expect(events[0].velocity > events[5].velocity, "a downstroke leans on the bass strings")
    }

    @Test func anUpstrokeSweepsHighToLowAndFaster() {
        var state = SynthState(sampleRate: 48_000, bpm: 120, stepsPerBar: 16)
        defer { state.deallocate() }
        let note = ScheduledNote(
            step: 0, instrument: .electricStrum, velocity: 0.8,
            params: NoteParams(pitch: 40, lengthSteps: 4, formant: 1, drive: 0.5, voice: 4))
        state.enqueue(SynthEvent(note))
        let events = (0..<6).map { state.pending[$0] }
        #expect(events.map { Int($0.pitch) } == StrumChord.power.intervals.reversed().map { 40 + $0 })
        let offsets = events.map { Int($0.offset) }
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $1 - $0 == 384 }, "\(offsets)")
        #expect(events.allSatisfy { $0.instrument == Instrument.electricGuitar.synthCode })
        #expect(events.allSatisfy { $0.flags & SynthEvent.StrumFlags.electric != 0 })
        #expect(events[5].velocity < events[0].velocity, "an upstroke leans on the treble strings")
    }

    @Test func aStrumRootFoldsIntoTheGuitarsLowRange() {
        for root: Int in [9, 28, 45, 64, 100] {
            var state = SynthState(sampleRate: 48_000, bpm: 120, stepsPerBar: 16)
            defer { state.deallocate() }
            state.enqueue(
                SynthEvent(
                    ScheduledNote(step: 0, instrument: .strum, velocity: 1, params: NoteParams(pitch: root))))
            let lowest = state.pending[0].pitch
            #expect(lowest >= 40 && lowest < 52 && Int(lowest) % 12 == root % 12, "root \(root) became \(lowest)")
        }
    }

    @Test func everyChordHasSixAscendingStringsAndANameThatRoundTrips() throws {
        for chord in StrumChord.allCases {
            #expect(chord.intervals.count == 6 && chord.intervals.first == 0)
            #expect(zip(chord.intervals, chord.intervals.dropFirst()).allSatisfy { $0 < $1 }, "\(chord)")
            #expect(StrumChord(voice: chord.voice) == chord)
            let json = try JSONEncoder().encode([chord])
            #expect(try JSONDecoder().decode([StrumChord].self, from: json) == [chord])
        }
        #expect(StrumChord(voice: -1) == StrumChord.allCases[5], "a negative voice wraps rather than crashing")
        #expect(StrumChord(voice: 7) == .minor)
    }

    // MARK: In the synth

    static func renderCore(_ notes: [ScheduledNote], seconds: Double = 3) -> (
        left: [Float], right: [Float], core: DropSynthCore
    ) {
        let core = DropSynthCore(sampleRate: 48_000, bpm: 120)
        core.setMasterVolume(1)
        for note in notes { core.schedule(note) }
        let frames = Int(48_000 * seconds)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < frames {
                    let n = min(512, frames - done)
                    core.render(frames: n, left: l.baseAddress! + done, right: r.baseAddress! + done)
                    done += n
                }
            }
        }
        return (left, right, core)
    }

    @Test func eachGuitarSoundsAndReportsItselfAsAHit() {
        for instrument in [Instrument.acousticGuitar, .electricGuitar, .bassGuitar, .strum, .electricStrum] {
            let note = ScheduledNote(
                step: 0, instrument: instrument, velocity: 0.9,
                params: NoteParams(pitch: 45, lengthSteps: 8, drive: 0.5))
            let out = Self.renderCore([note])
            let peak = out.left.map(abs).max() ?? 0
            #expect(peak > 0.05 && out.left.allSatisfy(\.isFinite), "\(instrument) peak \(peak)")
            #expect(out.core.takeHits() == [instrument], "\(instrument) hit \(out.core.takeHits())")
        }
    }

    @Test func aStrumBuildsUpOverTwentyFiveMillisecondsNotAllAtOnce() {
        let note = ScheduledNote(
            step: 0, instrument: .strum, velocity: 1, params: NoteParams(pitch: 45, lengthSteps: 8))
        let left = Self.renderCore([note], seconds: 0.3).left
        func energy(_ from: Double, _ to: Double) -> Float {
            left[Int(from * 48_000)..<Int(to * 48_000)].reduce(0) { $0 + $1 * $1 }
        }
        // The lead string sounds at once; the sixth is 60 ms later, so energy keeps climbing for a while.
        #expect(energy(0, 0.012) > 0)
        #expect(energy(0.06, 0.072) > energy(0, 0.012) * 2, "later strings should add to the lead string")
    }

    @Test func theGuitarsAreDeterministic() {
        let notes = (0..<16).map { i in
            ScheduledNote(
                step: i * 2, instrument: [.acousticGuitar, .electricGuitar, .bassGuitar, .strum][i % 4], velocity: 0.8,
                params: NoteParams(pitch: 40 + i, lengthSteps: 2, drive: 0.4, voice: i))
        }
        let a = Self.renderCore(notes, seconds: 2)
        let b = Self.renderCore(notes, seconds: 2)
        #expect(a.left == b.left && a.right == b.right)
    }

    @Test func aDenseFlurryOfStrumsStaysFiniteAndTheLimiterHoldsTheCeiling() {
        let notes = (0..<64).map { i in
            ScheduledNote(
                step: i, instrument: i % 2 == 0 ? .electricStrum : .strum, velocity: 1,
                params: NoteParams(pitch: 40 + i % 12, lengthSteps: 6, formant: Double(i % 2), drive: 1, voice: i))
        }
        let out = Self.renderCore(notes, seconds: 6)
        let peak = max(out.left.map(abs).max() ?? 0, out.right.map(abs).max() ?? 0)
        #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
        #expect(peak <= DSP.ceiling, "peak \(peak)")
    }

    @Test func theBassGuitarSitsOnTheBassBus() {
        let note = ScheduledNote(
            step: 0, instrument: .bassGuitar, velocity: 0.9, params: NoteParams(pitch: 33, lengthSteps: 4))
        let core = DropSynthCore(sampleRate: 48_000, bpm: 120)
        core.setMasterVolume(1)
        core.setMuted(true, for: .bass)
        core.schedule(note)
        var left = [Float](repeating: 0, count: 24_000)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                core.render(frames: 24_000, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        #expect(left[14_400...].allSatisfy { abs($0) < 1e-3 }, "muting the bass bus must silence the bass guitar")
    }

    @Test func theAcousticGuitarSitsOnTheFXBus() {
        let note = ScheduledNote(
            step: 0, instrument: .acousticGuitar, velocity: 0.9, params: NoteParams(pitch: 52, lengthSteps: 4))
        let core = DropSynthCore(sampleRate: 48_000, bpm: 120)
        core.setMasterVolume(1)
        core.setMuted(true, for: .fx)
        core.schedule(note)
        var left = [Float](repeating: 0, count: 24_000)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                core.render(frames: 24_000, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        #expect(left[14_400...].allSatisfy { abs($0) < 1e-3 }, "muting the FX bus must silence the guitars")
    }
}
