import Foundation
import NardukMusicCore
import NardukMusicRender
import Testing

/// The measuring tools (narduk-sound#36): loudness matching, the blind A/B key and the samey metric.
@Suite struct MeasureTests {
    static func sine(_ hz: Double, amplitude: Float, seconds: Double = 3, sampleRate: Double = 48_000) -> RenderedAudio
    {
        let samples = (0..<Int(seconds * sampleRate)).map {
            amplitude * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate))
        }
        return RenderedAudio(sampleRate: sampleRate, left: samples, right: samples)
    }

    static func noise(amplitude: Float, seconds: Double = 3, sampleRate: Double = 48_000) -> RenderedAudio {
        var rng = MusicRNG(seed: 7)
        let left = (0..<Int(seconds * sampleRate)).map { _ in amplitude * Float(rng.unit() * 2 - 1) }
        let right = (0..<Int(seconds * sampleRate)).map { _ in amplitude * Float(rng.unit() * 2 - 1) }
        return RenderedAudio(sampleRate: sampleRate, left: left, right: right)
    }

    // MARK: Loudness

    @Test func fullScaleStereoSineReadsZeroLUFS() {
        // BS.1770: a 0 dBFS 1 kHz sine in both channels reads 0 LUFS (K-weighting is ~0 dB at 1 kHz).
        let lufs = IntegratedLoudness.measure(Self.sine(1_000, amplitude: 1))
        #expect(abs(lufs) < 0.3, "\(lufs)")
        let quieter = IntegratedLoudness.measure(Self.sine(1_000, amplitude: 0.1))
        #expect(abs(quieter + 20) < 0.3, "\(quieter)")
        #expect(IntegratedLoudness.measure(Self.sine(1_000, amplitude: 0)) == IntegratedLoudness.silence)
    }

    @Test func matchingBringsTwoDifferentSignalsWithinHalfALU() {
        let a = Self.sine(220, amplitude: 0.6)
        let b = Self.noise(amplitude: 0.05)
        let pair = IntegratedLoudness.match(a, b)
        #expect(abs(pair.loudnessA - pair.loudnessB) > 6, "the signals start far apart")
        #expect(pair.difference <= 0.5, "\(pair.matchedA) vs \(pair.matchedB)")
        #expect(pair.gainA <= 0 && pair.gainB <= 0, "only turned down")
        #expect(pair.a.peak <= a.peak && pair.b.peak <= b.peak)
        // Gain only: the quieter side is untouched, bit for bit.
        #expect(pair.b.fingerprint == b.fingerprint)
    }

    // MARK: Blind key

    @Test func shufflingIsDeterministicBySeedAndCoversEveryExcerpt() {
        let excerpts = ABTest.excerptStarts()
        #expect(excerpts.count == 4)
        let first = ABTest.plan(seeds: [1, 2, 3, 4], excerpts: excerpts, shuffleSeed: 99)
        let again = ABTest.plan(seeds: [1, 2, 3, 4], excerpts: excerpts, shuffleSeed: 99)
        let other = ABTest.plan(seeds: [1, 2, 3, 4], excerpts: excerpts, shuffleSeed: 100)
        #expect(first == again)
        #expect(first != other)
        #expect(first.count == 16)
        #expect(first.map(\.id) == (1...16).map { String(format: "%02d", $0) })
        let pairs = Set(first.map { "\($0.seed)/\($0.excerpt?.rawValue ?? "")" })
        #expect(pairs.count == 16)
        // Both sides land on x somewhere, and the order is not the input order.
        #expect(Set(first.map(\.x)).count == 2)
        #expect(first.map(\.seed) != first.map(\.seed).sorted())
    }

    @Test func excerptsAreThirtyFiveSecondsAndDoNotOverlap() {
        let starts = ABTest.excerptStarts().values.sorted()
        let length = ABTest.songPlan.reduce(0) { $0 + $1.seconds }
        for (index, start) in starts.enumerated() {
            #expect(start + ABTest.excerptSeconds <= length)
            if index > 0 { #expect(starts[index - 1] + ABTest.excerptSeconds <= start) }
        }
    }

    @Test func optionSetsSetFlagsAndFields() throws {
        let base = MusicScenario(seed: 5, genre: .house)
        let b = try ABTest.applying("sampled,wide=false", to: base)
        #expect(b.flag("sampled") && !b.flag("wide") && !b.flag("missing"))
        let c = try ABTest.applying(#"{"variety": 0, "flags": {"x": true}}"#, to: b)
        #expect(c.variety == 0 && c.flag("x") && c.flag("sampled"))
        #expect(c.seed == 5 && c.genre == .house)
        #expect(try ABTest.applying("", to: base) == base)
    }

    @Test func scoringUnblindsAgainstTheKeyAndAppliesTheBar() throws {
        let trials = ABTest.plan(seeds: Array(1...12), shuffleSeed: 3)
        let key = ABTest.Key(
            source: "test", revision: "r", bankHash: "none", optionsA: "", optionsB: "sampled", shuffleSeed: 3,
            trials: trials, fixtures: [])
        func pick(_ trial: ABTest.Trial, _ side: ABTest.Side) -> String { trial.x == side ? "x" : "y" }
        // B preferred in 9 of 12, B or same on realism: passes.
        var answers = trials.enumerated().map { index, trial in
            ABTest.Answer(clip: trial.id, prefer: pick(trial, index < 9 ? .b : .a), moreReal: pick(trial, .b))
        }
        var score = ABTest.score(key: key, answers: answers)
        #expect(score.preferB == 9 && score.preferA == 3 && score.moreRealB == 12)
        #expect(score.passes, "\(score.verdict)")
        // One "A more real" fails it.
        answers[11].moreReal = pick(trials[11], .a)
        score = ABTest.score(key: key, answers: answers)
        #expect(!score.passes && score.moreRealA == 1)
        // Eight of twelve fails; eleven answers is not enough to judge.
        answers[11].moreReal = "same"
        answers[8].prefer = pick(trials[8], .a)
        #expect(!ABTest.score(key: key, answers: answers).passes)
        score = ABTest.score(key: key, answers: Array(answers.prefix(11)))
        #expect(!score.passes && score.unanswered == [trials[11].id])

        let csv = "clip,prefer,more_real\n1,\(pick(trials[0], .b)),same\n99,x,\n"
        let parsed = try ABTest.answers(from: Data(csv.utf8))
        #expect(parsed.count == 2)
        let partial = ABTest.score(key: key, answers: parsed)
        #expect(partial.preferB == 1 && partial.unknown == ["99"])
    }

    // MARK: Samey

    @Test func identicalTracksAreDistanceZeroAndOneCluster() {
        let window = SameyMetric.AudioWindow(start: 0.5, end: 2)
        let a = SameyMetric.features(genre: .house, seed: 1, window: window)
        let same = SameyMetric.features(genre: .house, seed: 1, window: window)
        let other = SameyMetric.features(genre: .house, seed: 2, window: window)
        #expect(a == same)
        #expect(TrackFeatures.distance(a, same) == 0)
        #expect(TrackFeatures.distance(a, other) > 0)
        #expect(TrackFeatures.distance(a, other) == TrackFeatures.distance(other, a))
        #expect(!a.instruments.isEmpty && a.noteDensity > 0 && abs(a.pitchClasses.reduce(0, +) - 1) < 1e-9)

        let duplicates = SameyReport(genre: .house, features: [a, same, a], threshold: 0.15)
        #expect(duplicates.meanNearestNeighbour == 0 && duplicates.clusters == 1 && duplicates.largestCluster == 3)
        let mixed = SameyReport(genre: .house, features: [a, other], threshold: 0)
        #expect(mixed.clusters == 2 && mixed.meanNearestNeighbour > 0)
    }

    @Test func audioFeaturesFindASineCentroid() {
        let tone = Self.sine(1_000, amplitude: 0.5, seconds: 1)
        let features = AudioFeatures.measure(tone.left, sampleRate: tone.sampleRate)
        #expect(abs(features.centroid - 1_000) < 60, "\(features.centroid)")
        #expect(features.mfccMeans.count == AudioFeatures.coefficientCount)
        #expect(features.flux < 0.01)
    }
}
