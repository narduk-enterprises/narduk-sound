import Foundation

/// How good a song is likely to sound, judged from its notes alone (no audio is rendered).
///
/// There is no ground truth for "good", so each part is a heuristic from music cognition: listeners like complexity in
/// a middle band (Berlyne's inverted U: too predictable bores, too random is noise), melodies that move mostly by step,
/// repetition with variation, and an energy arc that builds and releases. Each part is 0 ... 1; the total is their
/// weighted geometric mean, 0 ... 100, so a song weak on one axis cannot hide it behind the others.
///
/// Ported from Data Beats' `SongScore` (data-beats `Sources/DataBeatsKit/Critic.swift`) without its `coherence` part,
/// which judges how well a song follows a dataset. See `docs/song-critic.md`.
public struct SongScore: Sendable, Hashable, Codable {
    /// Lead melody: mostly stepwise with some leaps, a singable range, interval variety in the middle band.
    public var melody: Double
    /// Bars of the lead that echo an earlier bar without copying it.
    public var repetition: Double
    /// Energy arc: dynamic range, drops reached, builds that lift into them.
    public var arc: Double
    /// Sound-effect variety: several kinds of effect, spread out rather than clumped.
    public var events: Double
    /// Seconds of song judged.
    public var seconds: Double
    /// 0 ... 100.
    public var total: Double
    /// The raw measurements behind the parts, for tuning and display.
    public var raw: [String: Double]

    public init(
        melody: Double, repetition: Double, arc: Double, events: Double, seconds: Double, total: Double,
        raw: [String: Double] = [:]
    ) {
        self.melody = melody
        self.repetition = repetition
        self.arc = arc
        self.events = events
        self.seconds = seconds
        self.total = total
        self.raw = raw
    }

    /// Each part's weight in the total. Data Beats' weights (0.3, 0.2, 0.25, 0.1) with its 0.15 for `coherence`
    /// shared out in proportion, so they sum to 1.
    public static let weights: [(name: String, weight: Double)] = [
        ("melody", 0.3 / 0.85), ("repetition", 0.2 / 0.85), ("arc", 0.25 / 0.85), ("events", 0.1 / 0.85),
    ]

    /// The parts in a fixed order, for display.
    public var parts: [(name: String, value: Double)] {
        [("melody", melody), ("repetition", repetition), ("arc", arc), ("events", events)]
    }

    /// The weakest part, for a one-line verdict.
    public var weakest: String { parts.min { $0.value < $1.value }?.name ?? "" }

    /// The weighted geometric mean of the parts, 0 ... 100 (a part is floored at 0.02 so one zero does not erase the
    /// rest).
    public static func total(melody: Double, repetition: Double, arc: Double, events: Double) -> Double {
        let values = [melody, repetition, arc, events]
        var logSum = 0.0
        for (value, part) in zip(values, weights) { logSum += part.weight * log(max(0.02, value)) }
        return (100 * exp(logSum)).rounded()
    }
}
