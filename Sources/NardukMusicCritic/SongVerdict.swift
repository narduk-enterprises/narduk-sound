import Foundation
import NardukMusicCore

/// Whether a song is worth playing: its note score, its audio report, and the reasons it was dropped (empty when kept).
public struct SongVerdict: Sendable, Hashable, Codable {
    public var score: SongScore
    public var audio: AudioReport
    public var keep: Bool
    public var reasons: [String]

    /// The limits a song must stay inside to be kept. Every check is here, with its default; nil switches one off.
    public struct Thresholds: Sendable, Hashable, Codable {
        /// The lowest `SongScore.total` (0 ... 100) kept. 22 drops about the bottom quarter of conductor songs (30 seeds
        /// a genre, 90 bars; the medians run 25 ... 40).
        public var minTotal: Double? = 22
        /// The lowest any one part (0 ... 1) may score. Off by default: the conductor repeats its hook bar for bar, so
        /// `repetition` is 0 for over half of all songs (see `docs/song-critic.md`).
        public var minPart: Double?
        /// Clipped samples allowed.
        public var maxClippedSamples: Int? = 0
        /// Clicks allowed.
        public var maxClicks: Int? = 0
        /// Silence gaps longer than a bar allowed.
        public var maxSilenceGaps: Int? = 0
        /// The song's RMS must sit in this range, in dBFS.
        public var minRMSDB: Double? = -30
        public var maxRMSDB: Double? = -6
        /// The worst kick or snare onset off its due time, in ms.
        public var maxDrumOffsetMs: Double? = 5
        /// The share of synth blocks over their real-time budget. Render cost depends on the machine and the build
        /// (a debug build is many times slower), so it is off by default; turn it on where the song will play.
        public var maxOverBudgetShare: Double?

        public init(
            minTotal: Double? = 22, minPart: Double? = nil, maxClippedSamples: Int? = 0, maxClicks: Int? = 0,
            maxSilenceGaps: Int? = 0, minRMSDB: Double? = -30, maxRMSDB: Double? = -6, maxDrumOffsetMs: Double? = 5,
            maxOverBudgetShare: Double? = nil
        ) {
            self.minTotal = minTotal
            self.minPart = minPart
            self.maxClippedSamples = maxClippedSamples
            self.maxClicks = maxClicks
            self.maxSilenceGaps = maxSilenceGaps
            self.minRMSDB = minRMSDB
            self.maxRMSDB = maxRMSDB
            self.maxDrumOffsetMs = maxDrumOffsetMs
            self.maxOverBudgetShare = maxOverBudgetShare
        }
    }

    /// Judges a score and an audio report against `thresholds`.
    public init(score: SongScore, audio: AudioReport, thresholds: Thresholds = Thresholds()) {
        self.score = score
        self.audio = audio
        var reasons: [String] = []
        func format(_ value: Double) -> String { String(format: "%.1f", value) }
        if let limit = thresholds.minTotal, score.total < limit {
            reasons.append("score \(Int(score.total)) under \(Int(limit))")
        }
        if let limit = thresholds.minPart {
            for part in score.parts where part.value < limit {
                reasons.append("\(part.name) \(String(format: "%.2f", part.value)) under \(limit)")
            }
        }
        if let limit = thresholds.maxClippedSamples, audio.clippedSamples > limit {
            reasons.append("\(audio.clippedSamples) clipped samples")
        }
        if let limit = thresholds.maxClicks, audio.clicks > limit {
            reasons.append("\(audio.clicks) clicks")
        }
        if let limit = thresholds.maxSilenceGaps, audio.silenceGaps > limit {
            reasons.append("\(audio.silenceGaps) silences over a bar (longest \(format(audio.longestSilence)) s)")
        }
        if let limit = thresholds.minRMSDB, audio.rmsDB < limit {
            reasons.append("too quiet: \(format(audio.rmsDB)) dBFS RMS")
        }
        if let limit = thresholds.maxRMSDB, audio.rmsDB > limit {
            reasons.append("too loud: \(format(audio.rmsDB)) dBFS RMS")
        }
        if let limit = thresholds.maxDrumOffsetMs, let drums = audio.drums, drums.worstOffsetMs > limit {
            reasons.append("drums off by \(format(drums.worstOffsetMs)) ms at \(format(drums.worstAt)) s")
        }
        if let limit = thresholds.maxOverBudgetShare, let cost = audio.cost, cost.blocks > 0,
            Double(cost.overBudget) / Double(cost.blocks) > limit
        {
            reasons.append("\(cost.overBudget) of \(cost.blocks) blocks over budget (worst \(format(cost.worstMs)) ms)")
        }
        self.reasons = reasons
        keep = reasons.isEmpty
    }
}

extension SongCritic {
    /// Renders `seconds` of a song (twice: the song, then its drums alone), scores the notes the conductor wrote for
    /// that render, meters the audio and judges both. `signals` nil plays `energyWave`.
    public static func judge(
        settings: SongSettings, seconds: Double, signals: [MusicSignal]? = nil,
        thresholds: SongVerdict.Thresholds = SongVerdict.Thresholds()
    ) -> SongVerdict {
        let run = AudioCheck.render(settings: settings, seconds: seconds, signals: signals)
        let score = score(
            notes: run.notes, sections: run.sections, energy: run.energy, stepsPerBar: settings.stepsPerBar,
            secondsPerStep: run.secondsPerStep)
        return SongVerdict(score: score, audio: run.report, thresholds: thresholds)
    }
}
