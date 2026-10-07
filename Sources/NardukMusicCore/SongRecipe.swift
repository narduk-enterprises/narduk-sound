import Foundation

// A song described in a few plain fields, the shape a language model (or a person) can fill in: genre, mode, tempo,
// chord feel and a plan of sections. It maps, with no randomness, onto the two things the conductor takes: a
// `SongSettings` and a script of `MusicSignal`s whose level traces the plan's energy curve, so the song builds and
// settles the way the plan says. Every field arrives from outside the type system (a model's guided generation, a
// JSON file), so `validated()` clamps all of it and nothing downstream sees a value it cannot play.

/// What one stretch of the song does: a section kind held for some seconds at an intensity.
public struct SongRecipePart: Sendable, Hashable, Codable {
    /// The kind of section. The conductor decides the real section from the energy, so the part sets the energy the
    /// section needs (`SongRecipe.level(of:)`) and the script queues a drop where a drop part starts.
    public var section: SongSection
    /// How long the part lasts, in seconds.
    public var seconds: Double
    /// 0 ... 1: how hard the part pushes inside its section's own range (0.5 is the middle of the range).
    public var intensity: Double

    public init(section: SongSection, seconds: Double, intensity: Double = 0.5) {
        self.section = section
        self.seconds = seconds
        self.intensity = intensity
    }
}

/// A song as a recipe: see the file comment.
public struct SongRecipe: Sendable, Hashable, Codable {
    public static let tempoRange: ClosedRange<Double> = 60...200
    public static let secondsRange: ClosedRange<Double> = 20...300
    public static let partSecondsRange: ClosedRange<Double> = 4...90
    public static let maxParts = 12

    /// A short name for the song ("Rainy Night Lo-fi").
    public var title: String
    /// One sentence on what the recipe is going for; shown beside it.
    public var mood: String
    public var genre: Genre
    /// Pins the song to a mode; nil leaves it to the genre.
    public var mode: HarmonyMode?
    /// Beats per minute; nil uses the genre's own tempo.
    public var bpm: Double?
    /// The key's root as a pitch class, 0 (C) ... 11 (B).
    public var keyPitchClass: Int
    public var voicing: ChordVoicing?
    public var comping: CompingPattern?
    /// The plan, in order. Empty becomes the genre's default shape (`defaultParts`).
    public var parts: [SongRecipePart]
    /// Seeds the song; the same recipe and seed write the same song.
    public var seed: UInt64

    public init(
        title: String, mood: String = "", genre: Genre, mode: HarmonyMode? = nil, bpm: Double? = nil,
        keyPitchClass: Int = 5, voicing: ChordVoicing? = nil, comping: CompingPattern? = nil,
        parts: [SongRecipePart] = [], seed: UInt64 = 0x5EED
    ) {
        self.title = title
        self.mood = mood
        self.genre = genre
        self.mode = mode
        self.bpm = bpm
        self.keyPitchClass = keyPitchClass
        self.voicing = voicing
        self.comping = comping
        self.parts = parts
        self.seed = seed
    }

    // MARK: Validation

    /// The recipe with every field made playable: finite numbers clamped into range, a title that is never empty,
    /// at most `maxParts` parts of sane length, and a default plan when none is left. Idempotent.
    public func validated() -> SongRecipe {
        var recipe = self
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.title = String(name.prefix(48)).isEmpty ? genre.shortName : String(name.prefix(48))
        recipe.mood = String(mood.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        if let bpm {
            recipe.bpm = bpm.isFinite ? min(max(bpm, Self.tempoRange.lowerBound), Self.tempoRange.upperBound) : nil
        }
        recipe.keyPitchClass = ((keyPitchClass % 12) + 12) % 12
        recipe.parts = parts.prefix(Self.maxParts).map { part in
            SongRecipePart(
                section: part.section,
                seconds: part.seconds.isFinite
                    ? min(max(part.seconds, Self.partSecondsRange.lowerBound), Self.partSecondsRange.upperBound) : 16,
                intensity: part.intensity.isFinite ? min(max(part.intensity, 0), 1) : 0.5)
        }
        if recipe.parts.isEmpty { recipe.parts = Self.defaultParts(for: genre) }
        return recipe
    }

    /// A plan that suits the genre when the recipe gives none: calm ones settle, the rest build to a drop and back.
    public static func defaultParts(for genre: Genre) -> [SongRecipePart] {
        switch genre {
        case .chill, .lofi:
            [
                SongRecipePart(section: .intro, seconds: 20, intensity: 0.4),
                SongRecipePart(section: .build, seconds: 20, intensity: 0.5),
                SongRecipePart(section: .breakdown, seconds: 20, intensity: 0.6),
            ]
        default:
            [
                SongRecipePart(section: .intro, seconds: 16, intensity: 0.4),
                SongRecipePart(section: .build, seconds: 16, intensity: 0.6),
                SongRecipePart(section: .drop, seconds: 24, intensity: 0.7),
                SongRecipePart(section: .breakdown, seconds: 12, intensity: 0.5),
                SongRecipePart(section: .drop2, seconds: 24, intensity: 0.8),
            ]
        }
    }

    // MARK: Settings

    /// The settings the recipe asks for: genre, family, mode, tempo, key, chord feel and seed.
    public func settings() -> SongSettings {
        let recipe = validated()
        var settings = SongSettings(genre: recipe.genre)
        settings.bpm = recipe.bpm ?? recipe.genre.defaultBPM
        settings.keyRoot = 60 + recipe.keyPitchClass
        settings.seed = recipe.seed
        settings.family = recipe.genre.family
        settings.mode = recipe.mode
        settings.voicing = recipe.voicing
        settings.comping = recipe.comping
        return settings
    }

    // MARK: Energy

    /// The energy a section needs to be in the range the conductor reads it from (`DropConductor`'s default thresholds
    /// are 0.55 to build or drop and 0.4 to hold a drop), as `(low, high)`; intensity picks a point in between.
    public static func level(of section: SongSection) -> ClosedRange<Double> {
        switch section {
        case .intro: 0.08...0.3
        case .build: 0.6...0.8
        case .drop: 0.8...0.95
        case .breakdown: 0.15...0.35
        case .drop2: 0.85...1
        }
    }

    /// The part's target energy.
    public static func target(of part: SongRecipePart) -> Double {
        let range = level(of: part.section)
        return range.lowerBound + (range.upperBound - range.lowerBound) * part.intensity
    }

    /// Seconds a part takes to move from the previous part's energy to its own: a build climbs through its whole
    /// length, everything else settles in a couple of seconds.
    static func rampSeconds(of part: SongRecipePart) -> Double {
        part.section == .build ? part.seconds : min(2, part.seconds / 2)
    }

    /// Total length of the plan, in seconds.
    public var duration: Double { validated().parts.reduce(0) { $0 + $1.seconds } }

    /// The energy curve at `time` seconds: the plan's targets joined by ramps. Starts at the first part's target.
    public func energy(at time: Double) -> Double {
        let parts = validated().parts
        var start = 0.0
        var previous = Self.target(of: parts[0])
        for part in parts {
            let target = Self.target(of: part)
            let local = time - start
            if local < part.seconds {
                let ramp = Self.rampSeconds(of: part)
                guard local < ramp, ramp > 0 else { return target }
                return previous + (target - previous) * max(0, local) / ramp
            }
            previous = target
            start += part.seconds
        }
        return previous
    }

    // MARK: Script

    /// What to play: settings, the signals that trace the energy curve and the times a drop is queued.
    public struct Script: Sendable, Hashable {
        public var settings: SongSettings
        public var signals: [MusicSignal]
        /// Seconds at which a drop should be queued (where a `drop` or `drop2` part starts).
        public var dropTimes: [Double]
        public var seconds: Double
    }

    /// The song as a script: one signal every `interval` seconds carrying the energy as `level`, a character hint that
    /// follows the section, and the drop times.
    public func script(interval: Double = 0.25) -> Script {
        let recipe = validated()
        let step = interval.isFinite && interval > 0 ? interval : 0.25
        var signals: [MusicSignal] = []
        var dropTimes: [Double] = []
        var start = 0.0
        for part in recipe.parts {
            if part.section.isDrop { dropTimes.append(start) }
            let count = max(1, Int((part.seconds / step).rounded(.down)))
            for index in 0..<count {
                let time = start + Double(index) * step
                signals.append(
                    MusicSignal(
                        time: time, level: recipe.energy(at: time),
                        levelLabel: "\(recipe.title) \(part.section.rawValue)",
                        character: Self.character(of: part.section)))
            }
            start += part.seconds
        }
        return Script(settings: recipe.settings(), signals: signals, dropTimes: dropTimes, seconds: start)
    }

    /// The character hint a section sends, which steers the conductor's tracks.
    static func character(of section: SongSection) -> MusicCharacter {
        switch section {
        case .intro, .breakdown: .idle
        case .build: .busy
        case .drop: .surge
        case .drop2: .chaos
        }
    }
}
