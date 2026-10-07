import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The master cut (narduk-libs#1641): locked to the sample it fires on, a repeat that lands on the grid, a gate that
/// opens once a slice, and a live call that does the same.
@Suite struct MasterCutTests {
    static let rate = 48_000

    /// A core with a click every step and a slow tone, rendered with an optional cut note; returns the left channel.
    static func render(
        _ cut: ScheduledNote?, seconds: Double = 3, live: (mode: CutMode, at: Double)? = nil,
        notes: [ScheduledNote]? = nil
    ) -> [Float] {
        let core = DropSynthCore(sampleRate: Double(rate), bpm: 120)
        core.setMasterVolume(1)
        for step in 0..<64 {
            core.schedule(
                ScheduledNote(
                    step: step, instrument: .keys, velocity: 0.8,
                    params: NoteParams(pitch: Int(48 + (step * 5) % 17), lengthSteps: 1)))
        }
        if let cut { core.schedule(cut) }
        let frames = Int(Double(rate) * seconds)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var done = 0
                while done < frames {
                    if let live, done == Int(live.at * Double(rate)) / 512 * 512 {
                        core.cut(live.mode, division: .sixteenth, steps: 4)
                    }
                    let n = min(512, frames - done)
                    core.render(frames: n, left: l.baseAddress! + done, right: r.baseAddress! + done)
                    done += n
                }
            }
        }
        return left
    }

    // At 120 bpm a sixteenth step is exactly 0.125 s = 6000 samples.
    static let step = 6_000

    /// Runs `MasterCut` alone over a deterministic noise signal, as the core does: write the dry sample into the ring,
    /// then let the cut replace it. Returns the dry and wet signals.
    static func harness(
        _ mode: CutMode, slice: Int, length: Int, startAt: Int, total: Int, amount: Float = 0, seed: UInt32 = 1
    ) -> (dry: [Float], wet: [Float]) {
        let size = 1 << 16
        let ringLeft = UnsafeMutablePointer<Float>.allocate(capacity: size)
        let ringRight = UnsafeMutablePointer<Float>.allocate(capacity: size)
        ringLeft.initialize(repeating: 0, count: size)
        ringRight.initialize(repeating: 0, count: size)
        defer {
            ringLeft.deallocate()
            ringRight.deallocate()
        }
        var noise = NoiseSource(seed: 99)
        var cut = MasterCut()
        var dry: [Float] = []
        var wet: [Float] = []
        for n in 0..<total {
            let x = noise.next()
            ringLeft[n & (size - 1)] = x
            ringRight[n & (size - 1)] = x
            if n == startAt {
                cut.begin(
                    mode: mode, slice: slice, length: length, amount: amount, seed: seed, historyWrite: n)
            }
            let out = cut.process(x, x, historyLeft: ringLeft, historyRight: ringRight, mask: size - 1)
            dry.append(x)
            wet.append(out.0)
        }
        return (dry, wet)
    }

    @Test func aStutterBeginsOnItsSampleAndRepeatsOnTheGrid() {
        let slice = Self.step
        let start = 20_000  // not a multiple of anything
        let (dry, wet) = Self.harness(.stutter, slice: slice, length: 4 * slice, startAt: start, total: 60_000)
        #expect(zip(dry[..<start], wet[..<start]).allSatisfy { $0 == $1 }, "dry up to the cut's first sample")
        #expect(wet[start] != dry[start] || wet[start + 1] != dry[start + 1], "wet from its first samples")
        let inside = (start + 100)..<(start + 3 * slice - 100)
        #expect(inside.allSatisfy { wet[$0 + slice] == wet[$0] }, "the repeat period is one slice to the sample")
        #expect(
            ((start + 100)..<(start + slice - 100)).allSatisfy { wet[$0] == dry[$0 - slice] },
            "the slice is the one before the cut")
        let end = start + 4 * slice
        #expect(zip(dry[(end + 100)...], wet[(end + 100)...]).allSatisfy { $0 == $1 }, "back to the song")
    }

    @Test func aThirtySecondRepeatHasAHalfStepPeriodAndAPitchUpKeepsTheGrid() {
        let (_, wet) = Self.harness(.stutter, slice: 3_000, length: 24_000, startAt: 10_000, total: 40_000)
        #expect(((10_100)..<(10_000 + 20_000)).allSatisfy { wet[$0 + 3_000] == wet[$0] })
        // With pitch-up the read speeds up, but the cycle still turns over on the grid: it restarts every slice.
        let (_, rising) = Self.harness(
            .stutter, slice: 3_000, length: 24_000, startAt: 10_000, total: 40_000, amount: 1)
        #expect(rising[10_000 + 3_000 * 4 + 100] == rising[10_000 + 3_000 * 4 + 100], "stays finite")
        #expect(rising[10_100...34_000].allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test func aGateOpensOncePerSliceAndClosesBetween() {
        let note = ScheduledNote(
            step: 8, instrument: .cut, velocity: 1, params: .cut(.gate, division: .sixteenth, steps: 8, amount: 0))
        let wet = Self.render(note)
        let start = 8 * Self.step
        func energy(_ a: Int, _ b: Int) -> Float { wet[a..<b].reduce(0) { $0 + $1 * $1 } }
        for slice in 1..<6 {
            let first = start + slice * Self.step
            #expect(energy(first + 200, first + 2_800) > 0.01, "open in the first half of slice \(slice)")
            #expect(energy(first + 3_400, first + 5_800) < 1e-9, "closed in the second half of slice \(slice)")
        }
    }

    @Test func aReverseReadsTheLastSliceBackwards() {
        let slice = 6_000
        let start = 20_000
        let (dry, wet) = Self.harness(.reverse, slice: slice, length: 3 * slice, startAt: start, total: 50_000)
        #expect(
            ((start + 100)..<(start + slice - 100)).allSatisfy { wet[$0] == dry[start - 1 - ($0 - start)] })
        #expect(((start + 100)..<(start + 2 * slice - 100)).allSatisfy { wet[$0 + slice] == wet[$0] })
    }

    @Test func aChopReSlicesTheLastEightSlicesAndIsSeeded() {
        func chop(_ seed: Int) -> [Float] {
            Self.render(
                ScheduledNote(
                    step: 16, instrument: .cut, velocity: 1,
                    params: .cut(.chop, division: .sixteenth, steps: 8, amount: 0.5, seed: seed)))
        }
        #expect(chop(7) == chop(7))
        #expect(chop(7) != chop(8))
        #expect(chop(7).allSatisfy { $0.isFinite })
    }

    @Test func aLiveCutStartsOnTheNextBufferAndEnds() {
        let dry = Self.render(nil)
        let wet = Self.render(nil, live: (.stutter, 1.0))
        let start = Int(1.0 * Double(Self.rate)) / 512 * 512
        #expect(zip(dry[..<start], wet[..<start]).allSatisfy { $0 == $1 })
        #expect(wet[start..<(start + 400)] != dry[start..<(start + 400)])
        let end = start + 4 * Self.step + 200
        #expect(zip(dry[(end + 6_000)...], wet[(end + 6_000)...]).allSatisfy { $0 == $1 }, "and the song returns")
    }

    @Test func aCutNeverBreaksTheSignal() {
        for mode in CutMode.allCases {
            for division in CutDivision.allCases {
                let wet = Self.render(
                    ScheduledNote(
                        step: 4, instrument: .cut, velocity: 1,
                        params: .cut(mode, division: division, steps: 6, amount: 1, seed: 3)), seconds: 2)
                #expect(wet.allSatisfy { $0.isFinite && abs($0) < 2 }, "\(mode) \(division)")
            }
        }
    }

    @Test func divisionAndModeRoundTripThroughTheNoteFields() {
        for division in CutDivision.allCases { #expect(CutDivision(formant: division.formant) == division) }
        for mode in CutMode.allCases {
            let params = NoteParams.cut(mode, seed: 5)
            #expect(CutMode.allCases[(params.voice ?? 0) & 15] == mode && (params.voice ?? 0) >> 4 == 5)
        }
    }
}
