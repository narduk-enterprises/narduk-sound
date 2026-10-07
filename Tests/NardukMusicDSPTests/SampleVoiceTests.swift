import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The sampled female voice (narduk-libs#1641): the bank loads, its loops are seamless, a note sounds at its pitch,
/// the render is deterministic, a song without samples never touches the pool, and the master cut works on it.
@Suite struct SampleVoiceTests {
    static func bank() throws -> SampleBank { try #require(SampleBank.shared, "vocalsamples.bin did not load") }

    static func note(
        step: Int = 0, pitch: Int = 69, length: Int = 8, vowel: VocalVowel = .ah,
        technique: SampleTechnique = .straight,
        kind: SampleKind = .sustain, slice: Double? = nil, velocity: Double = 0.9
    ) -> ScheduledNote {
        ScheduledNote(
            step: step, instrument: .vocalSample, velocity: velocity,
            params: NoteParams(
                pitch: pitch, lengthSteps: length, formant: slice,
                voice: NoteParams.sampleVoice(vowel, technique: technique, kind: kind)))
    }

    @Test func theBankLoadsAndCoversEveryVowelAndTechnique() throws {
        let bank = try Self.bank()
        #expect(bank.sampleRate == 22_050)
        #expect(bank.totalSamples * 2 < 8_000_000, "the samples must stay under 8 MB: \(bank.totalSamples * 2) bytes")
        for vowel in VocalVowel.allCases where vowel != .mm {
            for technique in SampleTechnique.allCases {
                let roots = (0..<bank.clipCount).map { bank.clips[$0] }.filter {
                    $0.kind == .sustain && $0.vowel == vowel.index && $0.technique == technique
                }.map(\.root)
                #expect(roots.count >= 3, "\(vowel) \(technique): \(roots)")
                #expect((roots.max() ?? 0) - (roots.min() ?? 0) >= 6, "\(vowel) \(technique) spans a sixth or more")
            }
        }
        let kinds = Set((0..<bank.clipCount).map { bank.clips[$0].kind })
        #expect(kinds == Set(SampleKind.allCases))
        #expect(Self.garbage(Data("NVS1".utf8) + Data([4, 0, 0, 0, 1, 2])) == nil)
        #expect(Self.garbage(Data("nope".utf8)) == nil)
    }

    static func garbage(_ data: Data) -> SampleBank? { SampleBank(data: data) }

    @Test func everySustainLoopsWithoutAClick() throws {
        let bank = try Self.bank()
        for i in 0..<bank.clipCount where bank.clips[i].kind == .sustain {
            let c = bank.clips[i]
            let x = bank.pcm + c.offset
            // The step across the wrap (the last loop sample to the first) against the steps inside the loop.
            let wrap = abs(x[c.loopStart] - x[c.loopEnd - 1])
            var steps = (c.loopStart + 1..<c.loopEnd).map { abs(x[$0] - x[$0 - 1]) }
            steps.sort()
            let ceiling = steps[steps.count * 99 / 100]
            #expect(
                wrap <= 1.5 * ceiling + 0.002,
                "clip \(i) \(c.vowel) \(c.technique) wraps with a step of \(wrap) vs \(ceiling)")
            #expect(c.loopEnd - c.loopStart >= 2_000, "the loop is long enough not to buzz")
        }
    }

    @Test func aSustainSoundsAtItsPitchAndRendersTheSameEveryTime() throws {
        _ = try Self.bank()
        for pitch in [62, 69, 75] {
            let a = StringVoiceTests.renderCore([Self.note(pitch: pitch, length: 12)], seconds: 2)
            let b = StringVoiceTests.renderCore([Self.note(pitch: pitch, length: 12)], seconds: 2)
            #expect(a.left == b.left && a.right == b.right, "deterministic")
            #expect(a.left.allSatisfy { $0.isFinite })
            let peak = a.left.map(abs).max() ?? 0
            #expect(peak > 0.05 && peak <= 1.1, "peak \(peak)")
            #expect(a.core.takeHits() == [.vocalSample])
            // Pitch from autocorrelation of a steady stretch, within a quarter tone of the note.
            let from = 24_000
            let n = 4_096
            let x = Array(a.left[from..<(from + n)])
            let expected = 440 * pow(2, Double(pitch - 69) / 12)
            var best = 0
            var bestValue: Float = -1
            for lag in Int(48_000 / (expected * 1.2))...Int(48_000 / (expected / 1.2)) {
                var s: Float = 0
                for i in 0..<(n - lag) { s += x[i] * x[i + lag] }
                if s > bestValue {
                    bestValue = s
                    best = lag
                }
            }
            let heard = 48_000 / Double(best)
            let cents = 1_200 * log2(heard / expected)
            #expect(abs(cents) < 50, "pitch \(pitch): heard \(heard) Hz, expected \(expected) (\(cents) cents)")
        }
    }

    @Test func aSustainLastsForItsGateThenReleasesAndTheRoomDiesAway() throws {
        _ = try Self.bank()
        let out = StringVoiceTests.renderCore([Self.note(length: 8)], seconds: 8)
        let during = out.left[12_000..<18_000].map(abs).max() ?? 0
        #expect(during > 0.05, "still sounding at 0.3 s")
        let after = out.left[(48_000 * 7)...].map(abs).max() ?? 0
        #expect(after < 0.01, "the note and its room have died away: \(after)")
    }

    @Test func chopsAndRunsPlayOnceAndARunFitsItsNote() throws {
        let bank = try Self.bank()
        let chop = StringVoiceTests.renderCore([Self.note(length: 2, kind: .chop, slice: 0.4)], seconds: 1.5)
        #expect((chop.left.map(abs).max() ?? 0) > 0.05)
        let different = StringVoiceTests.renderCore([Self.note(length: 2, kind: .chop, slice: 0.9)], seconds: 1.5)
        #expect(chop.left != different.left, "the slice picks a different syllable")
        let runClip = (0..<bank.clipCount).map { bank.clips[$0] }.first { $0.kind == .run }
        #expect(runClip != nil)
        // A 2-second run: sounds through most of it, and is gone soon after.
        let run = StringVoiceTests.renderCore([Self.note(length: 8, kind: .run)], seconds: 6)
        #expect((run.left[24_000..<48_000].map(abs).max() ?? 0) > 0.05, "sounding mid-run")
        #expect((run.left[(48_000 * 5)...].map(abs).max() ?? 0) < 0.01)
    }

    @Test func aSongWithoutSamplesNeverTouchesThePool() throws {
        let plain = StringVoiceTests.renderCore(
            [ScheduledNote(step: 0, instrument: .kick, velocity: 0.9, params: NoteParams())], seconds: 1)
        let with = StringVoiceTests.renderCore(
            [ScheduledNote(step: 0, instrument: .kick, velocity: 0.9, params: NoteParams()), Self.note(step: 64)],
            seconds: 1)
        #expect(with.left[..<48_000] == plain.left[..<48_000], "a sample later in the song changes nothing before it")
    }

    @Test func theMasterCutStuttersTheSampledVoice() throws {
        _ = try Self.bank()
        // 120 bpm: a step is 6 000 samples. A sixteenth stutter from step 8 for 4 steps over a held sung note.
        let held = Self.note(step: 0, pitch: 66, length: 24, technique: .vibrato)
        let cut = ScheduledNote(
            step: 8, instrument: .cut, velocity: 1, params: .cut(.stutter, division: .sixteenth, steps: 4, amount: 0))
        let out = StringVoiceTests.renderCore([held, cut], seconds: 3)
        let dry = StringVoiceTests.renderCore([held], seconds: 3)
        let start = 8 * 6_000
        #expect(out.left[..<start] == dry.left[..<start], "dry until the cut")
        let slice = 6_000
        let inside = (start + 200)..<(start + 3 * slice - 200)
        #expect(
            inside.allSatisfy { out.left[$0 + slice] == out.left[$0] }, "the repeat period is one slice, to the sample")
        #expect(out.left[(start + 4 * slice + 200)...].count > 0)
    }
}
