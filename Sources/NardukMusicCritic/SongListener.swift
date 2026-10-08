import Foundation
import NardukMusicCore

/// Listens to a song bar by bar and scores it, over the whole song or a rolling window of recent bars.
///
/// It sees only what the conductor wrote (its notes, and the section and energy at each bar line) and keeps per-bar
/// summaries, so the same code judges a finished song and a live one: with a `window`, memory and the cost of
/// `score()` are bounded by it.
public struct SongListener: Sendable {
    struct Bar: Sendable {
        var notes: [ScheduledNote] = []
        var effects: [Instrument] = []
        var section: SongSection?
        var energy = 0.0
    }

    /// Bars kept; nil keeps the whole song.
    public let window: Int?
    public let stepsPerBar: Int
    public let secondsPerStep: Double
    private var bars: [Int: Bar] = [:]
    private var latest = -1

    public init(window: Int? = nil, stepsPerBar: Int = 16, secondsPerStep: Double = 60.0 / 140 / 4) {
        self.window = window.map { max(1, $0) }
        self.stepsPerBar = max(1, stepsPerBar)
        self.secondsPerStep = secondsPerStep
    }

    /// Bars heard so far (within the window).
    public var barCount: Int { bars.values.filter { $0.section != nil }.count }

    /// Records notes the conductor wrote; each lands in the bar its own step falls in.
    public mutating func hear(_ notes: [ScheduledNote]) {
        for note in notes where note.step >= 0 {
            let bar = note.step / stepsPerBar
            if let window, bar <= latest - window { continue }
            if LeadLine.rank(note) != nil { bars[bar, default: Bar()].notes.append(note) }
            if SongCritic.effectInstruments.contains(note.instrument) {
                bars[bar, default: Bar()].effects.append(note.instrument)
            }
        }
    }

    /// Records the section and energy at the start of `bar`.
    public mutating func mark(bar: Int, section: SongSection, energy: Double) {
        guard bar >= 0 else { return }
        bars[bar, default: Bar()].section = section
        bars[bar, default: Bar()].energy = energy
        if bar > latest {
            latest = bar
            if let window {
                for old in bars.keys where old <= latest - window { bars[old] = nil }
            }
        }
    }

    /// Records one step: the notes written at it and, on a bar line, the section and energy.
    public mutating func hear(step: Int, notes: [ScheduledNote], section: SongSection, energy: Double) {
        if step % stepsPerBar == 0 { mark(bar: step / stepsPerBar, section: section, energy: energy) }
        hear(notes)
    }

    /// The score of the marked bars heard so far (within the window).
    public func score() -> SongScore {
        let heard = bars.keys.sorted().compactMap { index -> Bar? in
            guard let bar = bars[index], bar.section != nil else { return nil }
            return bar
        }
        let lines = heard.map { LeadLine.line(ofBar: $0.notes) }
        let degrees = SongCritic.degrees(lines, barsPerKey: 8)
        var raw: [String: Double] = [:]
        let melody = SongCritic.melodyScore(degrees.flatMap { $0 }, raw: &raw)
        raw["leadNotesPerBar"] = Double(degrees.reduce(0) { $0 + $1.count }) / max(1, Double(heard.count))
        let repetition = SongCritic.repetitionScore(degrees, raw: &raw)
        let arc = SongCritic.arcScore(
            sections: heard.map { $0.section ?? .intro }, energy: heard.map(\.energy), raw: &raw)
        let events = SongCritic.eventScore(heard.map(\.effects), raw: &raw)
        let seconds = Double(heard.count * stepsPerBar) * secondsPerStep
        return SongScore(
            melody: melody, repetition: repetition, arc: arc, events: events, seconds: seconds,
            total: SongScore.total(melody: melody, repetition: repetition, arc: arc, events: events), raw: raw)
    }
}
