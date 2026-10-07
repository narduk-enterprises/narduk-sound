import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The synth under a track's timbre (narduk-sound#33): two seeds of one genre sound measurably different, the same
/// seed renders the same samples, repeated drum hits vary, and velocity moves brightness. Rendered silently at 48 kHz.
@Suite struct TimbreVariationTests {
    static let rate = 48_000.0

    /// Renders `notes` for `seconds` and returns the mono mix.
    static func render(_ notes: [ScheduledNote], seconds: Double = 1) -> [Float] {
        let core = DropSynthCore(sampleRate: rate, bpm: 120)
        for note in notes { core.schedule(note) }
        let frames = 512
        let total = Int(seconds * rate)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var out: [Float] = []
        out.reserveCapacity(total + frames)
        while out.count < total {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    core.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!)
                }
            }
            for i in 0..<frames { out.append((left[i] + right[i]) * 0.5) }
        }
        return out
    }

    /// A house stab chord, four steps long: filters and envelopes for the macro to move.
    static func stab(timbre: Int?, velocity: Double = 0.8) -> [ScheduledNote] {
        [60, 64, 67].map {
            ScheduledNote(
                step: 0, instrument: .keys, velocity: velocity,
                params: NoteParams(pitch: $0, lengthSteps: 4, voice: 1, timbre: timbre))
        }
    }

    /// The stab with hats and a snare under it: every drum path through the timbre.
    static func bar(timbre: Int?) -> [ScheduledNote] {
        var notes = stab(timbre: timbre)
        for step in stride(from: 0, to: 16, by: 2) {
            notes.append(ScheduledNote(step: step, instrument: .hat, velocity: 0.8, params: NoteParams(timbre: timbre)))
        }
        notes.append(ScheduledNote(step: 4, instrument: .snare, velocity: 0.8, params: NoteParams(timbre: timbre)))
        notes.append(ScheduledNote(step: 0, instrument: .kick, velocity: 0.9, params: NoteParams(timbre: timbre)))
        return notes
    }

    static func macro(seed: UInt64, genre: Genre = .house) -> Int {
        TimbreMacro.draw(genre: genre, seed: seed, variety: 1).1.packed
    }

    /// The share of the energy after the first quarter second: a longer decay keeps more of it.
    static func tailShare(_ x: [Float]) -> Double {
        let split = Int(0.25 * rate)
        let head = x[..<split].reduce(0.0) { $0 + Double($1 * $1) }
        let tail = x[split...].reduce(0.0) { $0 + Double($1 * $1) }
        return tail / max(head + tail, 1e-12)
    }

    @Test func twoSeedsRenderDifferentCentroidsAndEnvelopes() {
        var centroids: [Double] = []
        var tails: [Double] = []
        for seed in UInt64(1)...6 {
            let x = Self.render(Self.stab(timbre: Self.macro(seed: seed)), seconds: 0.6)
            centroids.append(SampleExpressionTests.centroid(x, from: 1_000))
            tails.append(Self.tailShare(x))
        }
        let low = centroids.min() ?? 0
        let high = centroids.max() ?? 0
        #expect(high / max(low, 1) > 1.1, "centroids \(centroids)")
        let shortest = tails.min() ?? 0
        let longest = tails.max() ?? 0
        #expect(longest / max(shortest, 1e-9) > 1.05, "tail shares \(tails)")
    }

    @Test func theSameSeedRendersTheSameSamples() {
        let timbre = Self.macro(seed: 42)
        #expect(
            Self.render(Self.bar(timbre: timbre), seconds: 0.5) == Self.render(Self.bar(timbre: timbre), seconds: 0.5))
    }

    /// The kick's body has no noise in it, so two standard hits are the same samples; under a timbre the round-robin
    /// moves each hit's pitch and decay.
    @Test func repeatedDrumHitsVaryOnlyUnderATimbre() {
        let c = SynthCoefficients(sampleRate: Self.rate)
        func hit(_ patch: TimbrePatch) -> [Float] {
            var kick = KickVoice()
            kick.trigger(velocity: 0.9, timbre: patch, c)
            return (0..<12_000).map { _ in kick.next(c) }
        }
        func difference(_ a: [Float], _ b: [Float]) -> Float {
            zip(a[500...], b[500...]).map { abs($0 - $1) }.max() ?? 0
        }
        #expect(difference(hit(.neutral), hit(.neutral)) == 0)
        let base = TimbrePatch(packed: Int64(TimbreMacro().packed), velocity: 0.9)
        var first = base
        first.vary(round: 1)
        var second = base
        second.vary(round: 2)
        #expect(difference(hit(first), hit(second)) > 0.01)
        #expect(first.pitch != second.pitch && first.hitDecay != second.hitDecay && first.noiseSeed != second.noiseSeed)
        #expect(abs(log2(first.pitch) * 1_200) <= 4.01 && abs(first.hitDecay - 1) <= 0.081)
    }

    /// The drums, keys and their round-robin together: the same seed renders the same samples.
    @Test func aBarUnderATimbreIsDeterministic() {
        let timbre = Self.macro(seed: 5, genre: .techno)
        let a = Self.render(Self.bar(timbre: timbre), seconds: 1)
        #expect(a == Self.render(Self.bar(timbre: timbre), seconds: 1))
        #expect(a != Self.render(Self.bar(timbre: nil), seconds: 1))
    }

    @Test func velocityMovesBrightness() {
        let timbre = TimbreMacro().packed
        let soft = Self.render(Self.stab(timbre: timbre, velocity: 0.3), seconds: 0.4)
        let hard = Self.render(Self.stab(timbre: timbre, velocity: 1), seconds: 0.4)
        #expect(SampleExpressionTests.centroid(hard, from: 1_000) > SampleExpressionTests.centroid(soft, from: 1_000))
    }

    /// A note without a macro, and one with a neutral patch, is the standard voice bit for bit.
    @Test func noMacroIsTheStandardSound() {
        #expect(!TimbrePatch(packed: 0, velocity: 1).isActive)
        var patch = TimbrePatch.neutral
        patch.vary(round: 3)
        #expect(patch == .neutral)
    }
}
