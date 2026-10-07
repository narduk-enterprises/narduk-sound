import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// One recorded voice, processed note by note (narduk-libs#1641): pitch automation, vowel morph, formant shift and
/// snap, character, filters, echo, reverse swell and stretch. All at 48 kHz, 120 bpm (a step is 6 000 samples).
@Suite struct SampleExpressionTests {
    static let rate = 48_000.0

    static func note(
        _ x: VocalExpression, pitch: Int = 69, length: Int = 12, step: Int = 0, vowel: VocalVowel = .ah,
        technique: SampleTechnique = .straight, kind: SampleKind = .sustain, slice: Double? = nil,
        velocity: Double = 0.9
    ) -> ScheduledNote {
        ScheduledNote(
            step: step, instrument: .vocalSample, velocity: velocity,
            params: NoteParams(
                pitch: pitch, lengthSteps: length, formant: slice,
                voice: NoteParams.sampleVoice(vowel, technique: technique, kind: kind)
            ).expressed(x))
    }

    static func render(_ notes: [ScheduledNote], seconds: Double = 3) -> [Float] {
        StringVoiceTests.renderCore(notes, seconds: seconds).left
    }

    /// Pitch in Hz of a stretch by autocorrelation with parabolic refinement.
    static func pitch(_ x: [Float], from: Int, length n: Int = 4_096, near expected: Double) -> Double {
        let window = Array(x[from..<(from + n)])
        let lo = Int(rate / (expected * 1.6))
        let hi = Int(rate / (expected / 1.6))
        var values = [Float](repeating: 0, count: hi + 2)
        for lag in max(lo - 1, 1)...(hi + 1) {
            var s: Float = 0
            for i in 0..<(n - lag) { s += window[i] * window[i + lag] }
            values[lag] = s
        }
        let best = (lo...hi).max { values[$0] < values[$1] } ?? lo
        let a = Double(values[best - 1])
        let b = Double(values[best])
        let c = Double(values[best + 1])
        let shift = 0.5 * (a - c) / (a - 2 * b + c)
        return rate / (Double(best) + (shift.isFinite ? shift : 0))
    }

    static func cents(_ heard: Double, _ expected: Double) -> Double { 1_200 * log2(heard / expected) }

    static func hz(_ pitch: Int) -> Double { 440 * pow(2, Double(pitch - 69) / 12) }

    /// Spectral centroid of 2 048 samples from `from`, by a direct transform (test-sized, no FFT dependency).
    static func centroid(_ x: [Float], from: Int, n: Int = 2_048) -> Double {
        var weighted = 0.0
        var total = 0.0
        for k in 1..<(n / 2) {
            var re = 0.0
            var im = 0.0
            for i in 0..<n {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
                let phase = 2 * Double.pi * Double(k * i) / Double(n)
                re += w * Double(x[from + i]) * cos(phase)
                im -= w * Double(x[from + i]) * sin(phase)
            }
            let magnitude = (re * re + im * im).squareRoot()
            weighted += magnitude * Double(k) * rate / Double(n)
            total += magnitude
        }
        return weighted / max(total, 1e-12)
    }

    /// The share of the spectrum's magnitude between two frequencies (2 048-point direct transform).
    static func share(_ x: [Float], from: Int, low: Double, high: Double, n: Int = 2_048) -> Double {
        var inside = 0.0
        var total = 0.0
        for k in 1..<(n / 2) {
            var re = 0.0
            var im = 0.0
            for i in 0..<n {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
                let phase = 2 * Double.pi * Double(k * i) / Double(n)
                re += w * Double(x[from + i]) * cos(phase)
                im -= w * Double(x[from + i]) * sin(phase)
            }
            let magnitude = (re * re + im * im).squareRoot()
            let f = Double(k) * rate / Double(n)
            total += magnitude
            if f >= low && f < high { inside += magnitude }
        }
        return inside / max(total, 1e-12)
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(x.count, 1))).squareRoot()
    }

    @Test func aPlainExpressionIsTheOriginalNote() throws {
        _ = try SampleVoiceTests.bank()
        let plain = Self.render([SampleVoiceTests.note(pitch: 69, length: 12)], seconds: 2)
        let nothing = Self.render([Self.note(VocalExpression(), pitch: 69, length: 12)], seconds: 2)
        #expect(plain == nothing, "no expression, no change")
    }

    @Test func snapAndFormantShiftKeepTheNotesPitch() throws {
        _ = try SampleVoiceTests.bank()
        for pitch in [64, 69, 74, 79] {
            for shift in [-6, 0, 4] {
                let x = VocalExpression(formantShift: shift, snap: true)
                let out = Self.render([Self.note(x, pitch: pitch, length: 16)], seconds: 2)
                let heard = Self.pitch(out, from: 30_000, near: Self.hz(pitch))
                let off = Self.cents(heard, Self.hz(pitch))
                #expect(abs(off) < 35, "pitch \(pitch) shift \(shift): \(off) cents off")
            }
        }
    }

    @Test func formantShiftBrightensAndDarkensWithoutMovingThePitch() throws {
        _ = try SampleVoiceTests.bank()
        let dark = Self.render([Self.note(VocalExpression(formantShift: -6), pitch: 69, length: 16)], seconds: 2)
        let bright = Self.render([Self.note(VocalExpression(formantShift: 6), pitch: 69, length: 16)], seconds: 2)
        let darkCentroid = Self.centroid(dark, from: 30_000)
        let brightCentroid = Self.centroid(bright, from: 30_000)
        #expect(brightCentroid > darkCentroid * 1.15, "dark \(darkCentroid) Hz, bright \(brightCentroid) Hz")
        let darkPitch = Self.pitch(dark, from: 30_000, near: 440)
        let brightPitch = Self.pitch(bright, from: 30_000, near: 440)
        let gap = abs(Self.cents(darkPitch, brightPitch))
        #expect(gap < 40, "the same pitch either way: \(gap) cents apart")
    }

    @Test func aScoopRisesIntoTheNoteAndAFallSinksOutOfIt() throws {
        _ = try SampleVoiceTests.bank()
        let scoop = Self.render(
            [Self.note(VocalExpression(scoop: -5, scoopTime: 1), pitch: 69, length: 16, technique: .straight)],
            seconds: 2)
        let early = Self.pitch(scoop, from: 600, length: 2_400, near: 440)
        let settled = Self.pitch(scoop, from: 40_000, near: 440)
        #expect(Self.cents(settled, early) > 150, "scooped up from \(early) to \(settled) Hz")
        let fall = Self.render(
            [Self.note(VocalExpression(bend: -6, bendSpan: 0.6), pitch: 69, length: 16, technique: .straight)],
            seconds: 2.4)
        let held = Self.pitch(fall, from: 14_000, near: 440)
        let end = Self.pitch(fall, from: 90_000, length: 3_000, near: 440)
        #expect(Self.cents(held, end) > 150, "fell from \(held) to \(end) Hz")
    }

    @Test func vibratoSwingsThePitchAndSnapSteadiesIt() throws {
        _ = try SampleVoiceTests.bank()
        func spread(_ x: VocalExpression) -> Double {
            let out = Self.render([Self.note(x, pitch: 69, length: 24, technique: .straight)], seconds: 3)
            let readings = stride(from: 30_000, to: 100_000, by: 3_000).map {
                Self.pitch(out, from: $0, length: 2_400, near: 440)
            }
            return Self.cents(readings.max() ?? 440, readings.min() ?? 440)
        }
        let steady = spread(VocalExpression())
        let deep = spread(VocalExpression(vibratoDepth: 1, vibratoRate: 0.6))
        let snapped = spread(VocalExpression(vibratoDepth: 1, snap: true))
        #expect(deep > steady + 25, "vibrato \(deep) cents vs steady \(steady)")
        #expect(snapped < 25, "snap holds the pitch: \(snapped) cents")
    }

    @Test func aMorphChangesTheVowelAcrossTheNote() throws {
        _ = try SampleVoiceTests.bank()
        let out = Self.render(
            [Self.note(VocalExpression(morph: .oo), pitch: 69, length: 24, vowel: .ah)], seconds: 3.2)
        let start = Self.centroid(out, from: 6_000)
        let end = Self.centroid(out, from: 130_000)
        #expect(start > end * 1.2, "ah (\(start) Hz) closes to oo (\(end) Hz)")
        let held = Self.render([Self.note(VocalExpression(), pitch: 69, length: 24, vowel: .ah)], seconds: 3.2)
        let heldEnd = Self.centroid(held, from: 130_000)
        #expect(heldEnd > end * 1.2, "without the morph it stays ah")
        let heard = Self.pitch(out, from: 130_000, near: 440)
        #expect(abs(Self.cents(heard, 440)) < 60, "the second vowel is in tune: \(heard) Hz")
    }

    @Test func gritAndBreathChangeTheCharacterWithoutMovingThePitch() throws {
        _ = try SampleVoiceTests.bank()
        let plain = Self.render([Self.note(VocalExpression(), pitch: 69, length: 16)], seconds: 2)
        let rough = Self.render([Self.note(VocalExpression(breath: 0.6, grit: 1), pitch: 69, length: 16)], seconds: 2)
        let roughCentroid = Self.centroid(rough, from: 30_000)
        let plainCentroid = Self.centroid(plain, from: 30_000)
        #expect(roughCentroid > plainCentroid * 1.2)
        let roughPitch = Self.pitch(rough, from: 30_000, near: 440)
        let plainPitch = Self.pitch(plain, from: 30_000, near: 440)
        let off = Self.cents(roughPitch, plainPitch)
        #expect(abs(off) < 40, "\(off) cents")
    }

    @Test func aTelephoneFilterRemovesTheLowEndAndTheTop() throws {
        _ = try SampleVoiceTests.bank()
        let plain = Self.render([Self.note(VocalExpression(), pitch: 62, length: 16)], seconds: 2)
        let phone = Self.render([Self.note(VocalExpression(filter: .telephone), pitch: 62, length: 16)], seconds: 2)
        let plainLow = Self.share(plain, from: 30_000, low: 0, high: 250)
        let phoneLow = Self.share(phone, from: 30_000, low: 0, high: 250)
        let plainTop = Self.share(plain, from: 30_000, low: 4_000, high: 24_000)
        let phoneTop = Self.share(phone, from: 30_000, low: 4_000, high: 24_000)
        #expect(phoneLow < plainLow * 0.6, "low end \(phoneLow) vs \(plainLow)")
        #expect(phoneTop < plainTop * 0.7, "top end \(phoneTop) vs \(plainTop)")
        #expect(phone.allSatisfy { $0.isFinite })
    }

    @Test func anEchoThrowRepeatsAfterTheNoteEnds() throws {
        _ = try SampleVoiceTests.bank()
        // 4 steps = 0.5 s of note; the echo repeats a dotted eighth (6 steps, 0.75 s) later.
        let dry = Self.render([Self.note(VocalExpression(), pitch: 69, length: 4)], seconds: 4)
        let wet = Self.render(
            [Self.note(VocalExpression(echo: .dottedEighth, echoSend: 1), pitch: 69, length: 4)], seconds: 4)
        let window = 48_000..<(48_000 + 20_000)
        #expect(Self.rms(wet[window]) > Self.rms(dry[window]) * 1.5, "an echo lands after the note has gone")
        let attackGap = abs(Self.rms(wet[2_000..<20_000]) - Self.rms(dry[2_000..<20_000]))
        #expect(attackGap < 0.03, "the note itself is unchanged: \(attackGap)")
    }

    @Test func aReverseSwellGrowsIntoItsEnd() throws {
        _ = try SampleVoiceTests.bank()
        let out = Self.render([Self.note(VocalExpression(reverse: true, swell: 1), length: 16)], seconds: 3.5)
        let early = Self.rms(out[6_000..<30_000])
        let late = Self.rms(out[72_000..<94_000])
        #expect(late > early * 4, "swells: \(early) to \(late)")
        // Without the reverb bloom, it is cut where the next phrase begins.
        let dry = Self.render([Self.note(VocalExpression(reverse: true), length: 16)], seconds: 3.5)
        let dryLate = Self.rms(dry[72_000..<94_000])
        let dryAfter = Self.rms(dry[100_000..<106_000])
        #expect(dryAfter < dryLate * 0.7, "cut at the downbeat (the room rings on): \(dryLate) then \(dryAfter)")
    }

    @Test func stretchHoldsAChopLongerThanItWas() throws {
        _ = try SampleVoiceTests.bank()
        let chop = Self.note(VocalExpression(), length: 16, kind: .chop, slice: 0.4)
        var stretched = Self.note(VocalExpression(stretch: 2), length: 16, kind: .chop, slice: 0.4)
        stretched.velocity = 0.9
        let a = Self.render([chop], seconds: 2)
        let b = Self.render([stretched], seconds: 2)
        let tail = 30_000..<60_000
        #expect(Self.rms(b[tail]) > Self.rms(a[tail]) * 2, "stretched \(Self.rms(b[tail])) vs \(Self.rms(a[tail]))")
        #expect(b.allSatisfy { $0.isFinite })
    }

    @Test func aFrozenNoteHoldsSteady() throws {
        _ = try SampleVoiceTests.bank()
        let out = Self.render([Self.note(VocalExpression(stretch: 3), length: 24)], seconds: 3.4)
        let a = Self.rms(out[30_000..<40_000])
        let b = Self.rms(out[100_000..<120_000])
        #expect(a > 0.02 && b > 0.02)
        #expect(b < a * 3 && a < b * 3, "no pumping: \(a) vs \(b)")
    }

    @Test func everyTreatmentIsDeterministicFiniteAndFreeOfClicks() throws {
        _ = try SampleVoiceTests.bank()
        let treatments: [VocalExpression] = [
            .torch, .power, .robot, .telephone, .morphing, .frozen,
            VocalExpression(vibratoDepth: 1, scoop: -8, bend: -8, bendSpan: 1, detune: -28, filter: .muffled),
            VocalExpression(echo: .eighth, echoSend: 1, reverse: true, swell: 1),
        ]
        let reference = Self.render([SampleVoiceTests.note(pitch: 69, length: 16)], seconds: 3)
        let referenceStep = zip(reference.dropFirst(), reference).map { abs($0 - $1) }.max() ?? 0
        for (n, x) in treatments.enumerated() {
            let notes = [Self.note(x, pitch: 69, length: 16, technique: .vibrato)]
            let a = Self.render(notes, seconds: 3)
            let again = Self.render(notes, seconds: 3)
            #expect(a == again, "treatment \(n) is deterministic")
            #expect(a.allSatisfy { $0.isFinite }, "treatment \(n) is finite")
            let peak = a.map(abs).max() ?? 0
            #expect(peak > 0.02 && peak < 1.2, "treatment \(n) peak \(peak)")
            let step = zip(a.dropFirst(), a).map { abs($0 - $1) }.max() ?? 0
            #expect(step < max(referenceStep * 3, 0.25), "treatment \(n) jumps by \(step) (plain \(referenceStep))")
        }
    }

    @Test func aStackOfDetunedVoicesIsThickerThanOne() throws {
        _ = try SampleVoiceTests.bank()
        let one = Self.render([Self.note(VocalExpression(vibratoDepth: 0.4), pitch: 69, length: 16)], seconds: 2)
        var voices = [Self.note(VocalExpression(vibratoDepth: 0.4), pitch: 69, length: 16)]
        for (n, detune) in [-8, 8, -4].enumerated() {
            var harmony = Self.note(
                VocalExpression(vibratoDepth: 0.4, formantShift: [-1, 2, -2][n], detune: detune),
                pitch: [73, 76, 81][n], length: 15)
            harmony.params.pan = [-0.6, 0.6, 0][n]
            harmony.params.delay = [0.12, 0.22, 0.32][n]
            voices.append(harmony)
        }
        let choir = Self.render(voices, seconds: 2)
        #expect(Self.rms(choir[30_000..<60_000]) > Self.rms(one[30_000..<60_000]) * 1.3)
        #expect(choir.allSatisfy { $0.isFinite })
    }
}
