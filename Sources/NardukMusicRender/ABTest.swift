import Foundation
import NardukMusicCore

/// A same-seed blind A/B session (narduk-sound#36): each trial plays one excerpt of one seed twice, with option set A
/// and with option set B, loudness-matched on the excerpt's integrated loudness (gain only: no peak normalising, no
/// limiting added to either side), as two unlabeled clips `x` and `y`. Which clip is A, and the trial order, come from
/// a shuffle seed and are written only to the hidden key, beside a fixture per seed that records everything the render
/// depended on.
public enum ABTest {
    public enum Side: String, Sendable, Hashable, Codable {
        case a = "A"
        case b = "B"
    }

    /// The passages a session plays, chosen from the song's plan before anything is rendered, so no one can pick
    /// the excerpts that flatter one side.
    public enum Excerpt: String, Sendable, Hashable, Codable, CaseIterable {
        /// The build into the first drop: its lead-in and its arrival.
        case transition
        /// Twelve seconds into the first drop, once the groove has settled.
        case groove1
        /// The breakdown from its start.
        case breakdown
        /// Twelve seconds into the second drop.
        case groove2
    }

    /// Excerpt length, in seconds.
    public static let excerptSeconds = 35.0

    /// The A/B song plan: long enough for two settled grooves, a breakdown and a transition that do not overlap.
    public static let songPlan: [SongRecipePart] = [
        SongRecipePart(section: .intro, seconds: 16, intensity: 0.4),
        SongRecipePart(section: .build, seconds: 20, intensity: 0.6),
        SongRecipePart(section: .drop, seconds: 48, intensity: 0.7),
        SongRecipePart(section: .breakdown, seconds: 36, intensity: 0.5),
        SongRecipePart(section: .build, seconds: 16, intensity: 0.6),
        SongRecipePart(section: .drop2, seconds: 48, intensity: 0.8),
    ]

    /// Where each excerpt starts in a song played to `parts`, in seconds; each lasts `excerptSeconds`.
    public static func excerptStarts(parts: [SongRecipePart] = songPlan) -> [Excerpt: Double] {
        var starts: [(SongSection, Double)] = []
        var time = 0.0
        for part in parts {
            starts.append((part.section, time))
            time += part.seconds
        }
        let total = time
        func first(_ section: SongSection) -> Double? { starts.first { $0.0 == section }?.1 }
        func clamp(_ t: Double) -> Double { min(max(0, t), max(0, total - excerptSeconds)) }
        var result: [Excerpt: Double] = [:]
        if let drop = first(.drop) {
            result[.transition] = clamp(drop - 23)
            result[.groove1] = clamp(drop + 12)
        }
        if let breakdown = first(.breakdown) { result[.breakdown] = clamp(breakdown) }
        if let drop2 = first(.drop2) { result[.groove2] = clamp(drop2 + 12) }
        return result
    }

    /// The song an A/B trial plays: `MusicScenario.song`, stretched to `songPlan`.
    public static func song(genre: Genre, seed: UInt64) -> MusicScenario {
        let script = SongRecipe(title: genre.shortName, genre: genre, parts: songPlan, seed: seed).script()
        var scenario = MusicScenario.song(genre: genre, seed: seed)
        scenario.seconds = script.seconds
        scenario.signals = script.signals
        scenario.actions = script.dropTimes.map { MusicScenario.Action(time: $0, queueDrop: true) }
        return scenario
    }

    public struct Trial: Sendable, Hashable, Codable {
        /// "01", "02", ...: the clips are `<id>-x.wav` and `<id>-y.wav`.
        public var id: String
        public var seed: UInt64
        /// The passage, nil for a whole-scenario clip.
        public var excerpt: Excerpt?
        /// Seconds into the render where the clip starts, and its length.
        public var from: Double
        public var seconds: Double
        /// Which option set clip x holds; clip y holds the other.
        public var x: Side
        public var y: Side { x == .a ? .b : .a }
        /// Integrated loudness of each clip's excerpt before and after matching, in LUFS, and the gain applied.
        public var loudnessA: Double?
        public var loudnessB: Double?
        public var gainA: Double?
        public var gainB: Double?
        public var matchedDifference: Double?

        public init(id: String, seed: UInt64, excerpt: Excerpt?, from: Double, seconds: Double, x: Side) {
            self.id = id
            self.seed = seed
            self.excerpt = excerpt
            self.from = from
            self.seconds = seconds
            self.x = x
        }

        enum CodingKeys: String, CodingKey {
            case id, seed, excerpt, from, seconds, x, loudnessA, loudnessB, gainA, gainB, matchedDifference
        }
    }

    /// Everything one side's render of one seed depended on: a seed alone does not reproduce it.
    public struct Fixture: Sendable, Hashable, Codable {
        public struct Energy: Sendable, Hashable, Codable {
            public var time: Double
            /// The level the input sent (the dial), and the conductor's smoothed energy.
            public var level: Double?
            public var energy: Double
            public var section: SongSection
        }

        public var side: Side
        public var seed: UInt64
        public var genre: Genre?
        public var bpm: Double
        public var keyRoot: Int
        public var variety: Double
        /// The first track's key and mode ("F# dorian") and the character it was written for.
        public var mode: String?
        public var character: MusicCharacter?
        /// Every track the conductor wrote during the render, in order.
        public var trackHistory: [TrackInfo]
        /// The energy timeline, once a second.
        public var energy: [Energy]
        /// Faders: offline renders play every instrument at 1 (an app fader under 1 drops notes; forever-loop#4)
        /// with the renderer's master volume.
        public var faders: String
        public var sampleRate: Double
        public var flags: [String: Bool]
        /// FNV-1a 64 of the scenario as JSON (sorted keys), and of the rendered samples (`RenderedAudio.fingerprint`).
        public var scenarioHash: String
        public var audioFingerprint: String
    }

    /// Renders `scenario` for `seconds` and records its fixture.
    public static func render(_ scenario: MusicScenario, side: Side, seconds: Double) -> (RenderedAudio, Fixture) {
        var tracks: [TrackInfo] = []
        var energy: [Fixture.Energy] = []
        let signals = scenario.timeline()
        var signalIndex = 0
        var level: Double?
        let audio = OfflineRenderer.render(scenario, seconds: seconds, observe: { renderer in
            if let track = renderer.snapshot.track, tracks.last?.number != track.number { tracks.append(track) }
            while signalIndex < signals.count, signals[signalIndex].time < renderer.time {
                if let value = signals[signalIndex].level { level = value }
                signalIndex += 1
            }
            if renderer.tick % Int(OfflineRenderer.tickRate) == 0 {
                energy.append(
                    Fixture.Energy(
                        time: renderer.time, level: level, energy: (renderer.snapshot.energy * 1_000).rounded() / 1_000,
                        section: renderer.snapshot.section))
            }
        })
        let settings = scenario.settings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(scenario)) ?? Data()
        let fixture = Fixture(
            side: side, seed: settings.seed, genre: scenario.genre, bpm: settings.bpm, keyRoot: settings.keyRoot,
            variety: settings.variety, mode: tracks.first?.key, character: tracks.first?.character,
            trackHistory: tracks, energy: energy, faders: "every instrument 1.0, master 0.8 (OfflineRenderer default)",
            sampleRate: audio.sampleRate, flags: scenario.flags ?? [:],
            scenarioHash: String(format: "%016llx", StableHash.fnv1a(String(decoding: json, as: UTF8.self))),
            audioFingerprint: String(format: "%016llx", audio.fingerprint))
        return (audio, fixture)
    }

    /// `seconds` of `audio` from `from`.
    public static func excerpt(_ audio: RenderedAudio, from: Double, seconds: Double) -> RenderedAudio {
        let start = min(Int(from * audio.sampleRate), audio.frameCount)
        let end = min(start + Int(seconds * audio.sampleRate), audio.frameCount)
        return RenderedAudio(
            sampleRate: audio.sampleRate, left: Array(audio.left[start..<end]), right: Array(audio.right[start..<end]))
    }

    /// The hidden key: everything needed to unblind a session and reproduce it.
    public struct Key: Sendable, Hashable, Codable {
        public var source: String
        /// The engine revision (git commit, with "-dirty" for uncommitted changes) and a hash of the DSP resource
        /// bank the render used.
        public var revision: String
        public var bankHash: String
        public var optionsA: String
        public var optionsB: String
        public var shuffleSeed: UInt64
        public var trials: [Trial]
        public var fixtures: [Fixture]

        public init(
            source: String, revision: String, bankHash: String, optionsA: String, optionsB: String,
            shuffleSeed: UInt64, trials: [Trial], fixtures: [Fixture]
        ) {
            self.source = source
            self.revision = revision
            self.bankHash = bankHash
            self.optionsA = optionsA
            self.optionsB = optionsB
            self.shuffleSeed = shuffleSeed
            self.trials = trials
            self.fixtures = fixtures
        }
    }

    /// The trials for every seed and excerpt, in a shuffled order with a coin flip per trial for which side is x. The
    /// same inputs and shuffle seed always give the same plan. An empty `excerpts` gives one whole-clip trial per seed
    /// from `from`.
    public static func plan(
        seeds: [UInt64], excerpts: [Excerpt: Double] = [:], from: Double = 0, seconds: Double = excerptSeconds,
        shuffleSeed: UInt64
    ) -> [Trial] {
        var rng = MusicRNG(seed: shuffleSeed ^ 0xAB7E_57AB_7E57_AB7E)
        var order: [(UInt64, Excerpt?, Double)] =
            excerpts.isEmpty
            ? seeds.map { ($0, nil, from) }
            : seeds.flatMap { seed in
                Excerpt.allCases.compactMap { kind in excerpts[kind].map { (seed, kind, $0) } }
            }
        if order.count > 1 {
            for i in stride(from: order.count - 1, to: 0, by: -1) {
                order.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
        }
        let width = max(2, String(order.count).count)
        return order.enumerated().map { index, item in
            let id = String(repeating: "0", count: max(0, width - String(index + 1).count)) + String(index + 1)
            return Trial(
                id: id, seed: item.0, excerpt: item.1, from: item.2, seconds: seconds,
                x: rng.next() & 1 == 0 ? .a : .b)
        }
    }

    /// The default shuffle seed for a seed list.
    public static func shuffleSeed(for seeds: [UInt64]) -> UInt64 {
        StableHash.fnv1a("abtest/" + seeds.map(String.init).joined(separator: ","))
    }

    /// `base` with the top-level fields of the JSON object `overrides` replaced (`flags` merge key by key). A value
    /// that does not start with `{` is shorthand for flags: `sampled` or `sampled=false,wide=true`.
    public static func applying(_ overrides: String, to base: MusicScenario) throws -> MusicScenario {
        let text = overrides.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return base }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] ?? [:]
        let changes: [String: Any]
        if text.hasPrefix("{") {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw OptionError(description: "options must be a JSON object: \(text)")
            }
            changes = parsed
        } else {
            var flags: [String: Bool] = [:]
            for item in text.split(separator: ",") {
                let parts = item.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let name = parts.first, !name.isEmpty else { continue }
                if parts.count == 2 {
                    guard let on = Bool(parts[1]) else {
                        throw OptionError(description: "flag \(name) needs true or false, not \(parts[1])")
                    }
                    flags[name] = on
                } else {
                    flags[name] = true
                }
            }
            changes = ["flags": flags]
        }
        for (key, value) in changes {
            if key == "flags", var flags = object["flags"] as? [String: Any], let more = value as? [String: Any] {
                for (name, on) in more { flags[name] = on }
                object["flags"] = flags
            } else {
                object[key] = value
            }
        }
        return try JSONDecoder().decode(MusicScenario.self, from: JSONSerialization.data(withJSONObject: object))
    }

    public struct OptionError: Error, CustomStringConvertible {
        public var description: String
    }

    // MARK: Scoring

    /// One answer: which clip of a trial was preferred, and which sounded more real ("x", "y", or "same").
    public struct Answer: Sendable, Hashable, Codable {
        public var clip: String
        public var prefer: String
        public var moreReal: String?

        public init(clip: String, prefer: String, moreReal: String? = nil) {
            self.clip = clip
            self.prefer = prefer
            self.moreReal = moreReal
        }
    }

    /// Reads answers from a JSON array of `{"clip", "prefer", "moreReal"}` or a CSV with a `clip,prefer,more_real`
    /// header. Clip ids match with or without leading zeros.
    public static func answers(from data: Data) throws -> [Answer] {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") { return try JSONDecoder().decode([Answer].self, from: Data(text.utf8)) }
        var lines = text.split(whereSeparator: \.isNewline).map {
            $0.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        if let header = lines.first, header.first?.lowercased() == "clip" { lines.removeFirst() }
        return lines.compactMap { fields in
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            return Answer(
                clip: fields[0], prefer: fields[1], moreReal: fields.count > 2 && !fields[2].isEmpty ? fields[2] : nil)
        }
    }

    /// A session unblinded, from B's side (B is the change under test).
    public struct Score: Sendable, Hashable, Codable {
        public var trials: Int
        public var answered: Int
        public var preferB: Int
        public var preferA: Int
        public var preferSame: Int
        public var moreRealB: Int
        public var moreRealA: Int
        public var moreRealSame: Int
        /// Trials in the key with no answer, and answers that name no trial in the key.
        public var unanswered: [String]
        public var unknown: [String]
        /// The bar for an instrument swap: B preferred in at least 3 of every 4 answered trials (9 of 12), over at
        /// least 12 answered trials, and A never picked as more real.
        public var passes: Bool
        public var verdict: String
        public var perTrial: [[String: String]]
    }

    public static let passTrials = 12
    public static let passPreferred = 9

    public static func score(key: Key, answers: [Answer]) -> Score {
        func normal(_ id: String) -> String {
            let trimmed = id.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
        func side(_ answer: String?, _ trial: Trial) -> Side?? {
            switch answer?.lowercased() {
            case "x": return .some(trial.x)
            case "y": return .some(trial.y)
            case "a", "b": return nil  // never accept a side name: the listener cannot know it
            case "same", "none", "=", "", nil: return .some(nil)
            default: return nil
            }
        }
        let trials = Dictionary(key.trials.map { (normal($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        var score = Score(
            trials: key.trials.count, answered: 0, preferB: 0, preferA: 0, preferSame: 0, moreRealB: 0, moreRealA: 0,
            moreRealSame: 0, unanswered: [], unknown: [], passes: false, verdict: "", perTrial: [])
        var seen: Set<String> = []
        for answer in answers {
            let id = normal(answer.clip)
            guard let trial = trials[id], !seen.contains(id), let prefer = side(answer.prefer, trial) else {
                score.unknown.append(answer.clip)
                continue
            }
            seen.insert(id)
            score.answered += 1
            switch prefer {
            case .b: score.preferB += 1
            case .a: score.preferA += 1
            case nil: score.preferSame += 1
            }
            let real: Side? = side(answer.moreReal, trial).flatMap { $0 }
            switch real {
            case .b: score.moreRealB += 1
            case .a: score.moreRealA += 1
            case nil: score.moreRealSame += 1
            }
            score.perTrial.append([
                "clip": trial.id, "seed": String(trial.seed), "excerpt": trial.excerpt?.rawValue ?? "whole", "preferred": prefer?.rawValue ?? "same",
                "moreReal": real?.rawValue ?? "same",
            ])
        }
        score.unanswered = key.trials.filter { !seen.contains(normal($0.id)) }.map(\.id)
        let enoughTrials = score.answered >= passTrials
        let preferredEnough = score.preferB * passTrials >= passPreferred * score.answered
        score.passes = enoughTrials && preferredEnough && score.moreRealA == 0
        score.verdict =
            if score.passes {
                "B passes: preferred in \(score.preferB) of \(score.answered), never less real"
            } else if !enoughTrials {
                "not enough trials: \(score.answered) answered, the bar needs \(passTrials)"
            } else if score.moreRealA > 0 {
                "B fails: A was more real in \(score.moreRealA) of \(score.answered)"
            } else {
                "B fails: preferred in \(score.preferB) of \(score.answered), the bar is \(passPreferred) of \(passTrials)"
            }
        return score
    }
}
