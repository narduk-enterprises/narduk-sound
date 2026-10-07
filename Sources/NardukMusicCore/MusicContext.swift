// MARK: - Music context

/// A stable lane for each `Instrument` in `HitCounters`. A switch, not `allCases` order, so adding an instrument is a
/// compile error here until it is given an explicit lane: lanes are never renumbered, never reused and stay below
/// `HitCounters.laneCount`.
extension Instrument {
    public var index: Int {
        switch self {
        case .kick: 0
        case .snare: 1
        case .hat: 2
        case .openHat: 3
        case .wobble: 4
        case .sub: 5
        case .glitch: 6
        case .scratch: 7
        case .laser: 8
        case .vox: 9
        case .riser: 10
        case .tapeStop: 11
        case .impact: 12
        case .keys: 13
        case .acousticGuitar: 14
        case .electricGuitar: 15
        case .bassGuitar: 16
        case .strum: 17
        case .electricStrum: 18
        }
    }
}

/// Per-instrument monotonic hit counters. The producer increments a lane on every hit; a consumer keeps the value it
/// last saw and takes `delta(since:)`, so skipping frames (a 30 fps consumer under thermal pressure) loses no hits and
/// two hits inside one poll count as two. Counters wrap, and the difference uses wrapping subtraction. A fixed-size
/// value: building, copying and diffing one never allocates.
public struct HitCounters: Sendable, Hashable {
    public static let laneCount = 32

    public var lanes = SIMD32<UInt32>(repeating: 0)

    public init() {}

    public subscript(instrument: Instrument) -> UInt32 {
        get { lanes[instrument.index] }
        set { lanes[instrument.index] = newValue }
    }

    /// Records one hit.
    public mutating func record(_ instrument: Instrument) {
        lanes[instrument.index] &+= 1
    }

    /// Hits per instrument since `previous`.
    public func delta(since previous: HitCounters) -> HitCounters {
        var out = HitCounters()
        out.lanes = lanes &- previous.lanes
        return out
    }
}

/// What music knows about itself, when the source is music. Visualizers use it when present and degrade without it
/// (docs/sound-contract.md section 2).
public struct MusicContext: Sendable, Hashable {
    /// Per-instrument hit counters, monotonic and wrapping. Consumers diff against the last value they saw.
    public var hitCounts: HitCounters
    /// Conductor step, 16ths.
    public var step: Int
    public var section: SongSection
    /// Conductor energy 0 ... 1.
    public var energy: Float
    /// Wobble LFO phase 0 ... 1 and filter cutoff 0 ... 1.
    public var wobblePhase: Float
    public var wobbleCutoff: Float

    // Beat clock: what a consumer needs to interpolate `step` between frames.
    public var isRunning: Bool
    /// Seconds per 16th (60 / bpm / 4).
    public var secondsPerStep: Double
    public var stepsPerBar: Int
    public var stepsPerPhrase: Int
    /// Progress through the current phrase, 0 ... 1.
    public var phraseProgress: Float

    // Conductor state the Data Beats timeline and stage draw.
    public var buildThreshold: Float
    public var dropThreshold: Float
    public var dropQueued: Bool

    // Notes: the pitches the music is playing (docs/sound-contract.md section 2). All empty from a source that does not
    // know its notes, and visualizers fall back to the analysis chroma.
    /// MIDI notes sounding now.
    public var heldNotes: NoteSet
    /// Per-note monotonic strike counters; consumers diff against the last value they saw (`struck(since:)`).
    public var noteCounts: NoteCounters
    /// The key's tonic as a pitch class (0 = C ... 11 = B), when the source knows it; nil otherwise.
    public var keyPitchClass: Int?
    /// True when the key is minor, when the source knows it.
    public var keyIsMinor: Bool?

    public init(
        hitCounts: HitCounters = HitCounters(), step: Int = 0, section: SongSection = .intro, energy: Float = 0,
        wobblePhase: Float = 0, wobbleCutoff: Float = 0, isRunning: Bool = false,
        secondsPerStep: Double = 60.0 / 140 / 4, stepsPerBar: Int = 16, stepsPerPhrase: Int = 128,
        phraseProgress: Float = 0, buildThreshold: Float = 0.55, dropThreshold: Float = 0.4, dropQueued: Bool = false,
        heldNotes: NoteSet = NoteSet(), noteCounts: NoteCounters = NoteCounters(), keyPitchClass: Int? = nil,
        keyIsMinor: Bool? = nil
    ) {
        self.hitCounts = hitCounts
        self.step = step
        self.section = section
        self.energy = energy
        self.wobblePhase = wobblePhase
        self.wobbleCutoff = wobbleCutoff
        self.isRunning = isRunning
        self.secondsPerStep = secondsPerStep
        self.stepsPerBar = stepsPerBar
        self.stepsPerPhrase = stepsPerPhrase
        self.phraseProgress = phraseProgress
        self.buildThreshold = buildThreshold
        self.dropThreshold = dropThreshold
        self.dropQueued = dropQueued
        self.heldNotes = heldNotes
        self.noteCounts = noteCounts
        self.keyPitchClass = keyPitchClass.map { (($0 % 12) + 12) % 12 }
        self.keyIsMinor = keyIsMinor
    }
}
