import Foundation

// The one input the conductor takes. A source (network input, CPU and builds, CI, sensors, market ticks) turns its
// own data into MusicSignals; its domain types stay in the app. Three things go in:
//   - a continuous level: either `level` (0 ... 1, the source decides what is loud) or a `flow` of amounts that the
//     conductor's own log-scaled model turns into energy;
//   - discrete cues, quantised onto the grid under per-bar budgets, each named by a label whose stable hash picks the
//     pitch or voice, so the same source always plays the same note;
//   - optionally a character hint (idle, busy, steady, surge, chaos) that picks and steers the tracks.
// Deterministic: the same seed and the same signals at the same steps write the same song, bit for bit.

/// Amounts that moved since the previous signal, for sources that measure throughput rather than a level.
///
/// The energy model reads `inbound + outbound` per second on a log scale against a ceiling that follows the busiest
/// moment seen, so any unit works for energy. The character classifier's thresholds are calibrated in bytes per
/// second (about 20 kB/s reads as idle, a sustained 1.5 MB/s one-way as a surge): a non-byte source either scales
/// to that or sends a `MusicSignal.character` hint.
public struct MusicFlow: Sendable, Hashable, Codable {
    /// Amount arriving (bytes received, for a network).
    public var inbound: Double
    /// Amount leaving (bytes sent, for a network).
    public var outbound: Double
    /// New bits of activity (connections opened, lookups, tool launches). They lift the energy of a busy-but-slow
    /// source and make it read as busy.
    public var starts: Double
    /// Faults (resets, retransmissions, failed lookups, failed jobs). Enough of them read as chaos.
    public var faults: Double
    /// Amount per named source (an app, a host, a job). The busiest one picks the track's bass variant and can lend
    /// the track its name.
    public var sources: [String: Double]

    public init(
        inbound: Double = 0, outbound: Double = 0, starts: Double = 0, faults: Double = 0,
        sources: [String: Double] = [:]
    ) {
        self.inbound = inbound
        self.outbound = outbound
        self.starts = starts
        self.faults = faults
        self.sources = sources
    }
}

/// A one-shot musical gesture asked for by a source. It waits in a queue for a slot the gesture may land on (lasers
/// on 8ths, vox on the beat, ...) and spends that bar's budget for its instrument; a cue that waits too long is
/// dropped. `label` names the cause in the legend ("laser ← TLS example.com").
public struct MusicCue: Sendable, Hashable, Codable {
    /// What the cue plays.
    public enum Gesture: String, Sendable, Hashable, Codable, CaseIterable {
        /// A hat accent (boosts the bed's hat, or adds one). In trap, two or more in one step roll the hats; now and
        /// then one plays a short glitch instead.
        case tick
        /// A short pitched laser on a chord tone; the tone is a stable hash of `key` (or `label`).
        case spark
        /// A one-step laser whose height on the chord is `height` (0 low ... 1 high).
        case zap
        /// A quiet high laser, only in the calm sections (intro and breakdown); dropped elsewhere.
        case sparkle
        /// A vox chop; the chop voice is `variant`, or a stable hash of `key` (or `label`).
        case voice
        /// A ghost snare between the backbeats.
        case ghost
        /// A two-step glitch stutter.
        case stutter
        /// A scratch on the off-8ths.
        case scratch
        /// A one-bar riser.
        case swell
        /// An impact on the beat.
        case impact
        /// A tape stop on beat 2 or 4, at most one per phrase.
        case tapeStop
    }

    public var gesture: Gesture
    /// The cause, as the legend shows it.
    public var label: String
    /// What the stable hash reads for pitch or voice; nil uses `label`.
    public var key: String?
    /// 0 ... 1 for `.zap`.
    public var height: Double?
    /// An explicit voice for `.voice`, instead of the hash.
    public var variant: Int?
    /// -1 (left) ... 1 (right); nil uses the signal's `pan`.
    public var pan: Double?

    public init(
        _ gesture: Gesture, label: String, key: String? = nil, height: Double? = nil, variant: Int? = nil,
        pan: Double? = nil
    ) {
        self.gesture = gesture
        self.label = label
        self.key = key
        self.height = height
        self.variant = variant
        self.pan = pan
    }

    /// What the stable hash reads.
    public var hashKey: String { key ?? label }

    public static func tick(_ label: String, pan: Double? = nil) -> MusicCue { MusicCue(.tick, label: label, pan: pan) }
    public static func spark(_ label: String, key: String? = nil, pan: Double? = nil) -> MusicCue {
        MusicCue(.spark, label: label, key: key, pan: pan)
    }
    public static func zap(_ label: String, height: Double, pan: Double? = nil) -> MusicCue {
        MusicCue(.zap, label: label, height: height, pan: pan)
    }
    public static func sparkle(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.sparkle, label: label, pan: pan)
    }
    public static func voice(_ label: String, key: String? = nil, variant: Int? = nil, pan: Double? = nil) -> MusicCue {
        MusicCue(.voice, label: label, key: key, variant: variant, pan: pan)
    }
    public static func ghost(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.ghost, label: label, pan: pan)
    }
    public static func stutter(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.stutter, label: label, pan: pan)
    }
    public static func scratch(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.scratch, label: label, pan: pan)
    }
    public static func swell(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.swell, label: label, pan: pan)
    }
    public static func impact(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.impact, label: label, pan: pan)
    }
    public static func tapeStop(_ label: String, pan: Double? = nil) -> MusicCue {
        MusicCue(.tapeStop, label: label, pan: pan)
    }
}

/// One delivery from a source to the conductor (`DropConductor.ingest(_:)`).
public struct MusicSignal: Sendable, Hashable, Codable {
    /// Seconds on the source's own monotonic clock. The conductor runs on the audio clock and does not read it; the
    /// offline renderer and scenario files use it to place signals on a timeline.
    public var time: Double
    /// 0 ... 1 energy chosen by the source. Once set it replaces the flow model (still smoothed with the usual attack
    /// and release) and stays until another signal sets a new one or `DropConductor.releaseLevel()` hands the energy
    /// back to `flow`. nil keeps the last value.
    public var level: Double?
    /// How the level reads in the legend ("CPU 82%", "4.1 MB/s"); nil keeps the last one.
    public var levelLabel: String?
    /// Amounts since the previous signal. They drive the energy while no `level` is set, and always feed the
    /// character classifier and the busiest-source tally.
    public var flow: MusicFlow?
    public var cues: [MusicCue]
    /// -1 (left) ... 1 (right) for cues that carry no pan of their own.
    public var pan: Double
    /// Pins the character instead of classifying the flow; it holds until another hint or
    /// `DropConductor.clearCharacterHint()`. nil keeps the current hint.
    public var character: MusicCharacter?

    public init(
        time: Double = 0, level: Double? = nil, levelLabel: String? = nil, flow: MusicFlow? = nil,
        cues: [MusicCue] = [], pan: Double = 0, character: MusicCharacter? = nil
    ) {
        self.time = time
        self.level = level
        self.levelLabel = levelLabel
        self.flow = flow
        self.cues = cues
        self.pan = pan
        self.character = character
    }
}
