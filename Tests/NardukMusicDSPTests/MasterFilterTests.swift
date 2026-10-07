import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The master filter (narduk-libs B8-drops): bypassed and bit-identical when idle, a real high-pass and low-pass when
/// engaged, smooth under a sweep, and back to bit-identical once snapped open.
@Suite struct MasterFilterTests {
    static let sr: Float = 48_000

    static func sine(_ hz: Float, _ n: Int) -> Float { 0.5 * sinf(DSP.twoPi * hz * Float(n) / sr) }

    /// RMS of `hz` through the filter held at `target`, after it has settled.
    static func gain(_ hz: Float, target: MasterFilter) -> Float {
        var state = MasterFilterState()
        let glide = MasterFilterState.glide(sampleRate: sr)
        var sum: Float = 0
        var count = 0
        for n in 0..<Int(sr) {
            let out = state.process(sine(hz, n), 0, target: target, sampleRate: sr, glide: glide).0
            if n > Int(sr) / 2 {
                sum += out * out
                count += 1
            }
        }
        return (sum / Float(count)).squareRoot() / (Float(0.5) / Float(2).squareRoot())
    }

    @Test func idleReturnsTheInputBitForBit() {
        var state = MasterFilterState()
        var noise = NoiseSource(seed: 7)
        let glide = MasterFilterState.glide(sampleRate: Self.sr)
        for _ in 0..<20_000 {
            let l = noise.next()
            let r = noise.next()
            let out = state.process(l, r, target: .idle, sampleRate: Self.sr, glide: glide)
            #expect(out.0.bitPattern == l.bitPattern && out.1.bitPattern == r.bitPattern)
        }
    }

    @Test func aCoreWithTheFilterSetIdleRendersExactlyAsOneNeverTouched() {
        func render(touch: Bool) -> [Float] {
            let core = DropSynthCore(sampleRate: 48_000)
            if touch { core.setMasterFilter(.idle) }
            for (step, instrument) in [(0, Instrument.kick), (4, .snare), (8, .kick), (10, .hat)] {
                core.schedule(ScheduledNote(step: step, instrument: instrument, velocity: 1))
            }
            core.schedule(
                ScheduledNote(step: 0, instrument: .sub, velocity: 1, params: NoteParams(pitch: 36, lengthSteps: 8)))
            var out: [Float] = []
            var left = [Float](repeating: 0, count: 480)
            var right = left
            for _ in 0..<200 {
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        core.render(frames: 480, left: l.baseAddress!, right: r.baseAddress!)
                    }
                }
                out += left + right
            }
            return out
        }
        let a = render(touch: false)
        let b = render(touch: true)
        #expect(a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(a.contains { abs($0) > 0.05 }, "the render was silent, so the identity proves nothing")
    }

    @Test func theHighPassCutsTheLowsAndKeepsTheHighs() {
        let target = MasterFilter(highPassHz: 2_000, resonance: 0)
        #expect(Self.gain(100, target: target) < 0.02)
        #expect(Self.gain(8_000, target: target) > 0.9)
    }

    @Test func theLowPassCutsTheHighsAndKeepsTheLows() {
        let target = MasterFilter(lowPassHz: 500, resonance: 0)
        #expect(Self.gain(8_000, target: target) < 0.02)
        #expect(Self.gain(100, target: target) > 0.9)
    }

    @Test func aSweepClosesTheLowsSmoothlyAndSnappingOpenRestoresTheInputExactly() {
        var state = MasterFilterState()
        let glide = MasterFilterState.glide(sampleRate: Self.sr)
        let sps = 60 / 140.0 / 4
        var windowRMS: [Float] = []
        var n = 0
        var previous: Float = 0
        // Hold for the full charge, with the target following the arranger's curve each 60 Hz tick.
        let held = Int(DropArranger.fullChargeSeconds * 1.5 * 60)
        var sum: Float = 0
        var maxJump: Float = 0
        for tick in 0..<held {
            let step = Int(Double(tick) / 60 / sps)
            let target = DropArranger.filterSweep(heldSteps: step, secondsPerStep: sps, genre: .house)
            for _ in 0..<800 {
                let out = state.process(Self.sine(150, n), 0, target: target, sampleRate: Self.sr, glide: glide).0
                maxJump = max(maxJump, abs(out - previous))
                previous = out
                sum += out * out
                n += 1
            }
            if tick % 15 == 14 {
                windowRMS.append((sum / (15 * 800)).squareRoot())
                sum = 0
            }
        }
        // The 150 Hz tone only ever gets quieter as the high-pass rises, to almost nothing at the top.
        #expect(zip(windowRMS, windowRMS.dropFirst()).allSatisfy { $1 <= $0 * 1.05 }, "\(windowRMS)")
        #expect(windowRMS.last! < windowRMS.first! * 0.15)
        #expect(maxJump < 0.2, "the sweep clicked: \(maxJump)")
        // Snap open: within 60 ms the filter is open, and a bit later it is bypassed again, exactly.
        for _ in 0..<Int(Self.sr * 0.5) {
            _ = state.process(Self.sine(150, n), 0, target: .idle, sampleRate: Self.sr, glide: glide)
            n += 1
        }
        for _ in 0..<2_000 {
            let x = Self.sine(150, n)
            n += 1
            let out = state.process(x, x, target: .idle, sampleRate: Self.sr, glide: glide)
            #expect(out.0.bitPattern == x.bitPattern && out.1.bitPattern == x.bitPattern)
        }
    }
}
