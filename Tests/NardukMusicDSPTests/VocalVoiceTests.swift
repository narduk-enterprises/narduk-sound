import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The wordless vocals (narduk-libs#1641): formant peaks where each vowel puts them, a held pitch, a choir that
/// settles, a chop that ends, and a synth that renders as before when none is sung.
@Suite struct VocalVoiceTests {
    static let sampleRate: Float = 48_000

    /// One lead voice, rendered mono from `from` to `to` seconds (before its vibrato starts at 0.3 s).
    static func render(
        vowel: Int, register: Float = 0.5, pitch: Float = 55, breath: Float = 0, chop: Bool = false,
        style: VocalStyle = .lead, gateSeconds: Float = 1, seconds: Float = 0.5
    ) -> [Float] {
        let c = SynthCoefficients(sampleRate: Double(sampleRate))
        var voice = VocalVoice(seed: 3)
        voice.trigger(
            pitch: pitch, velocity: 0.9, gateSamples: Int(gateSeconds * sampleRate), vowel: vowel, register: register,
            breath: breath, style: style, chop: chop, pan: 0, detuneCents: 0, phaseOffset: 0, level: 0.8, c)
        return (0..<Int(seconds * sampleRate)).map { _ in
            let s = voice.next(c)
            return (s.0 + s.1) * 0.5
        }
    }

    /// Hann-windowed magnitude of each harmonic of `pitch` up to 4 kHz over 0.12 ... 0.30 s (before the vibrato).
    static func spectrum(_ x: [Float], pitch: Float = 55) -> [(hz: Float, magnitude: Float)] {
        let from = Int(0.12 * sampleRate)
        let to = Int(0.30 * sampleRate)
        let n = to - from
        let window = (0..<n).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(n)) }
        let f0 = DSP.midiToHz(pitch)
        return (1...Int(4_000 / f0)).map { h in
            let hz = f0 * Float(h)
            var re: Float = 0
            var im: Float = 0
            let w = 2 * Float.pi * hz / sampleRate
            for i in 0..<n {
                let v = x[from + i] * window[i]
                re += v * cosf(w * Float(i))
                im -= v * sinf(w * Float(i))
            }
            return (hz, sqrtf(re * re + im * im))
        }
    }

    static func peak(_ bins: [(hz: Float, magnitude: Float)], in range: ClosedRange<Float>) -> Float {
        bins.filter { range.contains($0.hz) }.max { $0.magnitude < $1.magnitude }?.hz ?? 0
    }

    @Test func eachVowelPutsItsFormantsWhereASingerDoes() {
        // A low note (MIDI 38, 73 Hz) packs the partials close enough to trace the formant envelope.
        // (vowel, F1 band, F2 band or nil when F2 is under 1 kHz)
        let cases: [(VocalVowel, ClosedRange<Float>, ClosedRange<Float>?)] = [
            (.ah, 650...950, 1_000...1_400), (.oh, 350...600, nil), (.oo, 250...450, nil),
            (.eh, 330...500, 1_400...2_000), (.ee, 270...430, 1_500...2_300),
        ]
        for (vowel, f1, f2) in cases {
            let bins = Self.spectrum(Self.render(vowel: vowel.index, pitch: 38), pitch: 38)
            let first = Self.peak(bins, in: 200...1_000)
            #expect(f1.contains(first), "\(vowel): F1 peak at \(first) Hz, wanted \(f1)")
            if let f2 {
                let second = Self.peak(bins, in: 1_000...3_500)
                #expect(f2.contains(second), "\(vowel): F2 peak at \(second) Hz, wanted \(f2)")
            }
        }
    }

    @Test func eeIsBrighterThanOoAndAhIsOpener() {
        func band(_ bins: [(hz: Float, magnitude: Float)], _ r: ClosedRange<Float>) -> Float {
            bins.filter { r.contains($0.hz) }.reduce(0) { $0 + $1.magnitude * $1.magnitude }
        }
        let ee = Self.spectrum(Self.render(vowel: VocalVowel.ee.index))
        let oo = Self.spectrum(Self.render(vowel: VocalVowel.oo.index))
        let ah = Self.spectrum(Self.render(vowel: VocalVowel.ah.index))
        #expect(
            band(ee, 1_700...2_500) / band(ee, 250...450) > 4 * band(oo, 1_700...2_500) / band(oo, 250...450),
            "ee carries its energy in F2; oo does not")
        #expect(band(ah, 650...950) > 4 * band(oo, 650...950), "ah opens the first formant")
    }

    @Test func aSopranoRegisterRaisesTheSecondFormantOfEe() {
        let alto = Self.spectrum(Self.render(vowel: VocalVowel.ee.index, register: 0))
        let soprano = Self.spectrum(Self.render(vowel: VocalVowel.ee.index, register: 1))
        let a = Self.peak(alto, in: 1_200...3_200)
        let s = Self.peak(soprano, in: 1_200...3_200)
        #expect(s > a + 200, "alto ee peaks near \(a) Hz, soprano ee near \(s) Hz")
    }

    @Test func theVoiceHoldsItsPitch() {
        for pitch: Float in [48, 57, 64, 72] {
            let out = Self.render(vowel: 0, pitch: pitch, seconds: 0.5)
            let expected = DSP.midiToHz(pitch)
            let measured = StringVoiceTests.frequency(out, expected: expected)
            #expect(abs(StringVoiceTests.cents(measured, expected)) < 15, "MIDI \(pitch): \(measured) vs \(expected)")
        }
    }

    @Test func breathAddsAperiodicNoiseWithoutLosingTheVowel() {
        // 200 Hz is exactly 240 samples, so a perfectly periodic voice repeats itself and the residual is the noise.
        let pitch = 69 + 12 * log2f(200 / 440)
        func residual(_ x: [Float]) -> Float {
            var diff: Float = 0
            var total: Float = 0
            for i in Int(0.15 * Self.sampleRate)..<Int(0.30 * Self.sampleRate) {
                diff += (x[i] - x[i + 240]) * (x[i] - x[i + 240])
                total += x[i] * x[i]
            }
            return diff / total
        }
        let clean = Self.render(vowel: 0, pitch: pitch, breath: 0)
        let breathy = Self.render(vowel: 0, pitch: pitch, breath: 1)
        #expect(residual(clean) < 0.01, "a clean voice repeats: \(residual(clean))")
        #expect(residual(breathy) > 0.05, "a breathy one does not: \(residual(breathy))")
        #expect((650...950).contains(Self.peak(Self.spectrum(breathy, pitch: pitch), in: 200...1_000)))
    }

    @Test func aVoiceStaysFiniteAndInRangeAtTheExtremes() {
        for vowel in 0..<6 {
            for pitch: Float in [36, 96] {
                for register: Float in [0, 1] {
                    let out = Self.render(vowel: vowel, register: register, pitch: pitch, breath: 1, seconds: 1.2)
                    #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1.6 }, "vowel \(vowel) pitch \(pitch)")
                    #expect((out.map(abs).max() ?? 0) > 0.02)
                }
            }
        }
    }

    @Test func aChopOpensFromOoAndEndsOnItsOwn() {
        let early = Self.render(vowel: VocalVowel.ah.index, chop: true, gateSeconds: 0.15, seconds: 1)
        func energy(_ x: [Float], _ a: Float, _ b: Float) -> Float {
            x[Int(a * 48_000)..<Int(b * 48_000)].reduce(0) { $0 + $1 * $1 }
        }
        #expect(energy(early, 0.1, 0.14) > 0)
        #expect(energy(early, 0.8, 1.0) == 0, "a chop's release is over inside 0.65 s")
    }

    // MARK: Feels

    static func renderFeel(_ feel: VocalFeel, seconds: Float = 1.5) -> [Float] {
        let c = SynthCoefficients(sampleRate: Double(sampleRate))
        let patch = VocalPatch.patch(chop: false, style: .lead, feel: feel)
        var voice = VocalVoice(seed: 3)
        voice.trigger(
            pitch: 57, velocity: 0.9, gateSamples: Int(3 * sampleRate), vowel: 0, register: 0.5,
            breath: patch.breathDefault, style: .lead, feel: feel, chop: false, pan: 0, detuneCents: 0, phaseOffset: 0,
            level: 0.8, c)
        return (0..<Int(seconds * sampleRate)).map { _ in
            let s = voice.next(c)
            return (s.0 + s.1) * 0.5
        }
    }

    /// How bright a voice is: the energy above 1.5 kHz against the energy below it, in dB, over 0.9 ... 1.3 s (a
    /// Hann-windowed Goertzel scan on a 20 Hz grid to 8 kHz). The first two formants hold most of a voice's energy, so a
    /// plain spectral centroid of one voice barely differs from another's; this ratio moves with the upper formants,
    /// the breath and the slope.
    static func brightness(_ x: [Float]) -> Float {
        let from = Int(0.9 * sampleRate)
        let n = Int(0.4 * sampleRate)
        let window = (0..<n).map { 0.5 - 0.5 * cosf(2 * .pi * Float($0) / Float(n)) }
        var low: Float = 0
        var high: Float = 0
        for hz in stride(from: Float(100), through: 8_000, by: 20) {
            var re: Float = 0
            var im: Float = 0
            let w = 2 * Float.pi * hz / sampleRate
            for i in 0..<n {
                let v = x[from + i] * window[i]
                re += v * cosf(w * Float(i))
                im -= v * sinf(w * Float(i))
            }
            if hz < 1_500 { low += re * re + im * im } else { high += re * re + im * im }
        }
        return 10 * log10f(max(high, 1e-12) / max(low, 1e-12))
    }

    @Test func everyFeelSoundsDifferentInBrightnessAndVibratoRate() {
        let feels = VocalFeel.allCases
        let brightness = feels.map { Self.brightness(Self.renderFeel($0)) }
        let rates = feels.map { VocalPatch.patch(chop: false, style: .lead, feel: $0).vibratoRate }
        for a in 0..<feels.count {
            for b in (a + 1)..<feels.count {
                // Distinct by ear: a clearly different brightness, or a clearly different vibrato speed.
                #expect(
                    abs(brightness[a] - brightness[b]) >= 3 || abs(rates[a] - rates[b]) >= 1.2,
                    "\(feels[a]) \(brightness[a]) dB \(rates[a]) Hz vs \(feels[b]) \(brightness[b]) dB \(rates[b]) Hz")
                #expect(
                    abs(rates[a] - rates[b]) >= 0.35, "\(feels[a]) \(rates[a]) Hz vs \(feels[b]) \(rates[b]) Hz")
            }
        }
    }

    @Test func everyFeelStaysFiniteAndAudible() {
        for feel in VocalFeel.allCases {
            let out = Self.renderFeel(feel, seconds: 2)
            #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1.6 }, "\(feel)")
            #expect((out.map(abs).max() ?? 0) > 0.03, "\(feel) is too quiet")
        }
    }

    @Test func feelsRoundTripThroughTheVoiceField() {
        for feel in VocalFeel.allCases {
            let v = NoteParams.vocalVoice(.oh, style: .solo, feel: feel)
            #expect(VocalFeel(voice: v) == feel && v & 7 == VocalVowel.oh.index && VocalStyle(voice: v) == .solo)
        }
        #expect(VocalFeel(voice: NoteParams.vocalVoice(.ah)) == .classic, "the default feel is the original voice")
    }

    // MARK: In the synth

    @Test func aChoirIsThreeVoicesThatSettleAndFinish() {
        let note = ScheduledNote(
            step: 0, instrument: .vocal, velocity: 0.9,
            params: NoteParams(pitch: 57, lengthSteps: 8, voice: NoteParams.vocalVoice(.ah, style: .choir)))
        let out = StringVoiceTests.renderCore([note], seconds: 4)
        let peak = out.left.map(abs).max() ?? 0
        #expect(peak > 0.05 && out.left.allSatisfy(\.isFinite), "peak \(peak)")
        #expect(out.core.takeHits() == [.vocal])
        // Stereo: the choir is spread, so the channels differ.
        #expect(zip(out.left, out.right).contains { abs($0 - $1) > 0.01 })
        let tail = out.left.suffix(2_000).map(abs).max() ?? 0
        #expect(tail < 0.01, "the choir and its room should have died away: \(tail)")
    }

    @Test func aLeadTakesOverFromTheLastLead() {
        var state = SynthState(sampleRate: 48_000, bpm: 120, stepsPerBar: 16)
        defer { state.deallocate() }
        let lead = NoteParams(pitch: 64, lengthSteps: 16, voice: NoteParams.vocalVoice(.oh, style: .lead))
        state.enqueue(SynthEvent(ScheduledNote(step: 0, instrument: .vocal, velocity: 0.9, params: lead)))
        state.enqueue(SynthEvent(ScheduledNote(step: 0, instrument: .vocal, velocity: 0.9, params: lead)))
        state.trigger(state.pending[0])
        #expect(state.vocalsLive == 1)
        state.trigger(state.pending[1])
        let fading = (0..<SynthState.vocalCount).filter { state.vocals[$0].active }.count
        #expect(fading == 2, "the old lead is still fading out while the new one starts")
    }

    @Test func aSongWithoutVocalsNeverTouchesThem() {
        let note = ScheduledNote(step: 0, instrument: .acousticGuitar, velocity: 0.9, params: NoteParams(pitch: 52))
        let out = StringVoiceTests.renderCore([note], seconds: 1)
        #expect(out.core.takeHits() == [.acousticGuitar])
        let state = SynthState(sampleRate: 48_000, bpm: 120, stepsPerBar: 16)
        defer { state.deallocate() }
        #expect(state.vocalsLive == 0 && state.vocalTail == 0)
    }

    @Test func vowelAndStyleRoundTripThroughTheVoiceField() {
        for vowel in VocalVowel.allCases {
            for style in VocalStyle.allCases {
                let v = NoteParams.vocalVoice(vowel, style: style)
                #expect(v & 7 == vowel.index && VocalStyle(voice: v) == style)
            }
        }
        #expect(Instrument(synthCode: Instrument.vocal.synthCode) == .vocal)
        #expect(Instrument(synthCode: Instrument.vocalChop.synthCode) == .vocalChop)
    }
}
