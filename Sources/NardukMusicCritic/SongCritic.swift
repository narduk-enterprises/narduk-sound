import Foundation
import NardukMusicCore

/// Scores a song from the notes a `DropConductor` writes (see `SongScore` and `docs/song-critic.md`).
public enum SongCritic {
    /// The effect instruments whose variety and spread make the `events` part.
    public static let effectInstruments: [Instrument] = [
        .glitch, .scratch, .laser, .riser, .tapeStop, .impact, .cut, .vocalChop,
    ]

    /// Scores a finished song: the conductor's notes, and per bar its section and energy at the bar line (both
    /// arrays have one entry per bar). A length factor rewards 1.5 ... 5 minute songs, as in Data Beats.
    public static func score(
        notes: [ScheduledNote], sections: [SongSection], energy: [Double], stepsPerBar: Int = 16,
        secondsPerStep: Double
    ) -> SongScore {
        var listener = SongListener(stepsPerBar: stepsPerBar, secondsPerStep: secondsPerStep)
        for (bar, section) in sections.enumerated() {
            listener.mark(bar: bar, section: section, energy: bar < energy.count ? energy[bar] : 0)
        }
        listener.hear(notes.filter { $0.step < sections.count * max(1, stepsPerBar) })
        return lengthWeighted(listener.score())
    }

    /// Plays `bars` bars of a song through the conductor symbolically (no audio: milliseconds a minute) and scores
    /// them. `signals` are delivered at the step their `time` falls in (at the settings' tempo); nil plays
    /// `energyWave`, a rise and fall every 32 bars, because a conductor with no input never leaves its intro.
    public static func score(settings: SongSettings, bars: Int, signals: [MusicSignal]? = nil) -> SongScore {
        let signals = signals ?? energyWave(bars: bars, settings: settings)
        var conductor = DropConductor(settings: settings)
        var listener = SongListener(stepsPerBar: settings.stepsPerBar, secondsPerStep: settings.secondsPerStep)
        var next = 0
        for step in 0..<(max(0, bars) * settings.stepsPerBar) {
            let end = Double(step + 1) * settings.secondsPerStep
            while next < signals.count, signals[next].time < end {
                conductor.ingest(signals[next])
                next += 1
            }
            let notes = conductor.advance(throughStep: step)
            listener.hear(
                step: step, notes: notes, section: conductor.snapshot.section, energy: conductor.snapshot.energy)
        }
        return lengthWeighted(listener.score())
    }

    /// A level that rises from 0.05 to 0.95 and falls back every `periodBars` bars, one signal a beat: a stand-in
    /// for a source, so a song builds, drops and breaks down. It starts low, so the first half period is the intro.
    public static func energyWave(bars: Int, settings: SongSettings, periodBars: Int = 32) -> [MusicSignal] {
        let beats = max(0, bars) * settings.stepsPerBar / 4
        let beatSeconds = settings.secondsPerStep * 4
        let beatsPerBar = Double(settings.stepsPerBar) / 4
        return (0..<beats).map { beat in
            let bar = Double(beat) / beatsPerBar
            let level = 0.5 - 0.45 * cos(2 * Double.pi * bar / Double(max(1, periodBars)))
            return MusicSignal(time: Double(beat) * beatSeconds, level: level)
        }
    }

    /// The whole-song length factor: a song shorter than 45 s or longer than 10 minutes scores 70% of its parts.
    static func lengthWeighted(_ score: SongScore) -> SongScore {
        var score = score
        let length = band(score.seconds, low: 45, idealLow: 90, idealHigh: 300, high: 600)
        score.raw["lengthFactor"] = 0.7 + 0.3 * length
        score.total = (score.total * (0.7 + 0.3 * length)).rounded()
        return score
    }

    // MARK: Lead degrees

    /// Each bar's lead as scale degrees. The tonic is read per `barsPerKey` bars from the lead's own pitches (tracks
    /// change key), and each carrier instrument is moved by whole octaves so its median sits in the same octave: the
    /// hook passing from the wobble to keys two octaves up is not a leap.
    static func degrees(_ lines: [[LeadLine.Note]], barsPerKey: Int) -> [[Int]] {
        var degrees = lines.map { $0.map { _ in 0 } }
        for start in Swift.stride(from: 0, to: lines.count, by: max(1, barsPerKey)) {
            let range = start..<min(lines.count, start + max(1, barsPerKey))
            let tonic = LeadLine.tonic(of: lines[range].flatMap { $0.map(\.pitch) })
            for bar in range {
                degrees[bar] = lines[bar].map { LeadLine.degree($0.pitch, tonic: tonic) }
            }
        }
        var byInstrument: [Instrument: [Int]] = [:]
        for (bar, line) in lines.enumerated() {
            for (index, note) in line.enumerated() {
                byInstrument[note.instrument, default: []].append(degrees[bar][index])
            }
        }
        let shift = byInstrument.mapValues { values -> Int in
            let median = values.sorted()[values.count / 2]
            return 7 * (median >= 0 ? median / 7 : -((6 - median) / 7))
        }
        for (bar, line) in lines.enumerated() {
            for (index, note) in line.enumerated() { degrees[bar][index] -= shift[note.instrument, default: 0] }
        }
        return degrees
    }

    // MARK: Parts (Data Beats' formulas)

    /// 1 inside [idealLow, idealHigh], falling linearly to 0 at `low` and `high`.
    public static func band(_ x: Double, low: Double, idealLow: Double, idealHigh: Double, high: Double) -> Double {
        if x < idealLow { return max(0, (x - low) / max(1e-9, idealLow - low)) }
        if x > idealHigh { return max(0, (high - x) / max(1e-9, high - idealHigh)) }
        return 1
    }

    /// On scale degrees (7 to the octave): stepwise share, leaps, range, interval entropy and repeated notes.
    static func melodyScore(_ degrees: [Int], raw: inout [String: Double]) -> Double {
        guard degrees.count >= 8 else { return 0 }
        let intervals = zip(degrees, degrees.dropFirst()).map { $1 - $0 }
        let moves = intervals.filter { $0 != 0 }
        guard !moves.isEmpty else { return 0.05 }
        let stepwise = Double(moves.filter { abs($0) == 1 }.count) / Double(moves.count)
        let leaps = Double(moves.filter { abs($0) >= 3 }.count) / Double(moves.count)
        let sorted = degrees.sorted()
        let range = Double(sorted[sorted.count * 95 / 100] - sorted[sorted.count * 5 / 100])
        // Interval entropy, normalised (summed in a fixed order so the score is the same in every process): 0 = one interval forever, 1 = every interval from -4 to +4 equally likely.
        var counts: [Int: Int] = [:]
        for interval in intervals { counts[max(-4, min(4, interval)), default: 0] += 1 }
        let n = Double(intervals.count)
        let entropy = -counts.values.sorted().reduce(0) { $0 + (Double($1) / n) * log2(Double($1) / n) } / log2(9)
        let repeated = Double(intervals.filter { $0 == 0 }.count) / n
        raw["stepwise"] = stepwise
        raw["leaps"] = leaps
        raw["range"] = range
        raw["intervalEntropy"] = entropy
        raw["repeatedNotes"] = repeated
        return band(stepwise, low: 0.25, idealLow: 0.55, idealHigh: 0.85, high: 1.01) * 0.3
            + band(leaps, low: -0.01, idealLow: 0.03, idealHigh: 0.15, high: 0.4) * 0.15
            + band(range, low: 1, idealLow: 4, idealHigh: 9, high: 14) * 0.2
            + band(entropy, low: 0.2, idealLow: 0.45, idealHigh: 0.7, high: 0.92) * 0.25
            + band(repeated, low: -0.01, idealLow: 0.08, idealHigh: 0.35, high: 0.7) * 0.1
    }

    /// A bar echoes if an earlier bar within the last eight has a close (but not identical) shape, transposition free.
    static func repetitionScore(_ bars: [[Int]], raw: inout [String: Double]) -> Double {
        let shapes = bars.filter { $0.count >= 2 }.map { bar in bar.map { $0 - bar[0] } }
        guard shapes.count >= 8 else { return 0.2 }
        var echoes = 0
        var copies = 0
        for i in 1..<shapes.count {
            var best = Int.max
            for j in max(0, i - 8)..<i { best = min(best, distance(shapes[i], shapes[j])) }
            if best == 0 { copies += 1 } else if best <= 2 { echoes += 1 }
        }
        let total = Double(shapes.count - 1)
        raw["echoBars"] = Double(echoes) / total
        raw["copyBars"] = Double(copies) / total
        return band(Double(echoes + copies) / total, low: 0.05, idealLow: 0.3, idealHigh: 0.6, high: 0.9)
            * (1 - min(0.8, max(0, Double(copies) / total - 0.25) * 2))
    }

    /// Sum of absolute degree differences over the shorter bar, plus a cost per missing note.
    static func distance(_ a: [Int], _ b: [Int]) -> Int {
        zip(a, b).reduce(0) { $0 + min(3, abs($1.0 - $1.1)) } + 2 * abs(a.count - b.count)
    }

    /// Energy spread, the share of drop bars, drops per 64 bars, section variety and how far builds lift into drops.
    static func arcScore(sections: [SongSection], energy: [Double], raw: inout [String: Double]) -> Double {
        guard sections.count >= 8, energy.count == sections.count else { return 0 }
        let sorted = energy.sorted()
        let spread = sorted[sorted.count * 9 / 10] - sorted[sorted.count / 10]
        let bars = Double(sections.count)
        let dropShare = Double(sections.filter(\.isDropLike).count) / bars
        let kinds = Set(sections).count
        let drops = zip(sections, sections.dropFirst()).filter { !$0.isDropLike && $1.isDropLike }.count
        let dropsPer64 = Double(drops) / bars * 64
        // Builds that pay off: energy rising over the 8 bars before each drop.
        var lifts: [Double] = []
        for i in 8..<sections.count where !sections[i - 1].isDropLike && sections[i].isDropLike {
            lifts.append(energy[i - 1] - energy[i - 8])
        }
        let lift = lifts.isEmpty ? 0 : lifts.reduce(0, +) / Double(lifts.count)
        raw["energySpread"] = spread
        raw["dropShare"] = dropShare
        raw["dropsPer64Bars"] = dropsPer64
        raw["sectionKinds"] = Double(kinds)
        raw["buildLift"] = lift
        return band(spread, low: 0.05, idealLow: 0.3, idealHigh: 0.75, high: 1.1) * 0.25
            + band(dropShare, low: 0.02, idealLow: 0.25, idealHigh: 0.5, high: 0.8) * 0.2
            + band(dropsPer64, low: 0, idealLow: 1, idealHigh: 2, high: 4) * 0.2
            + min(1, Double(kinds - 1) / 3) * 0.1
            + band(lift, low: -0.1, idealLow: 0.12, idealHigh: 0.6, high: 1.2) * 0.25
    }

    /// Variety of effect kinds (entropy) and how evenly they are spread over 4-bar windows.
    static func eventScore(_ bars: [[Instrument]], raw: inout [String: Double]) -> Double {
        let all = bars.flatMap { $0 }
        guard all.count >= 4 else { return 0.1 }
        var counts: [Instrument: Int] = [:]
        for kind in all { counts[kind, default: 0] += 1 }
        let n = Double(all.count)
        let entropy =
            -counts.values.sorted().reduce(0) { $0 + (Double($1) / n) * log2(Double($1) / n) }
            / log2(Double(effectInstruments.count))
        let windows = Swift.stride(from: 0, to: bars.count, by: 4).map { start in
            Double(bars[start..<min(bars.count, start + 4)].reduce(0) { $0 + $1.count })
        }
        let mean = windows.reduce(0, +) / Double(windows.count)
        let cv = mean > 0 ? sqrt(windows.reduce(0) { $0 + pow($1 - mean, 2) } / Double(windows.count)) / mean : 2
        raw["effectKindEntropy"] = entropy
        raw["effectCV"] = cv
        raw["effectsPerBar"] = n / max(1, Double(bars.count))
        return band(entropy, low: 0.1, idealLow: 0.45, idealHigh: 0.85, high: 1.01) * 0.6
            + band(cv, low: -0.01, idealLow: 0.2, idealHigh: 0.8, high: 2) * 0.4
    }
}

extension SongSection {
    /// DROP or DROP 2 (Core keeps its own `isDrop` internal).
    var isDropLike: Bool { self == .drop || self == .drop2 }
}
