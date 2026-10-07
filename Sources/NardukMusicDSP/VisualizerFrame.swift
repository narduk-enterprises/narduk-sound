import NardukMusicCore
import NardukSoundAnalysis

// MARK: - Visualizer feed

/// Audio analysis the engine publishes for the visualizers (~60 Hz), off the render thread.
///
/// Deprecated in 0.4.0, kept for one minor version: the engine now publishes a `SoundFrame` (what any sound is doing)
/// and a `MusicContext` (what the music knows about itself), and this type is built from the two. Migrate by reading
/// `DropEngine.latestSound` and `DropEngine.latestMusic`; hits become `HitCounters` you diff, so skipped frames lose
/// nothing (docs/sound-contract.md sections 2 and 4).
@available(
    *, deprecated,
    message: "Read DropEngine.latestSound (SoundFrame) and latestMusic (MusicContext) instead; removed after 0.4.x."
)
public struct VisualizerFrame: Sendable, Hashable {
    /// Log-spaced magnitude bands, 0 ... 1 (64 bands).
    public var spectrum: [Float]
    /// The latest output waveform, mono, -1 ... 1 (512 samples).
    public var waveform: [Float]
    /// Current wobble LFO phase 0 ... 1 and filter cutoff 0 ... 1, for wobble-synced visuals.
    public var wobblePhase: Float
    public var wobbleCutoff: Float
    /// Peak and RMS of the master bus, in dBFS.
    public var peakDB: Float
    public var rmsDB: Float
    /// Instruments that fired since the previous frame (kick flash, snare hit, ...).
    public var hits: Set<Instrument>
    public var step: Int
    public var section: SongSection

    public init(
        spectrum: [Float] = Array(repeating: 0, count: 64), waveform: [Float] = Array(repeating: 0, count: 512),
        wobblePhase: Float = 0, wobbleCutoff: Float = 0, peakDB: Float = -120, rmsDB: Float = -120,
        hits: Set<Instrument> = [], step: Int = 0, section: SongSection = .intro
    ) {
        self.spectrum = spectrum
        self.waveform = waveform
        self.wobblePhase = wobblePhase
        self.wobbleCutoff = wobbleCutoff
        self.peakDB = peakDB
        self.rmsDB = rmsDB
        self.hits = hits
        self.step = step
        self.section = section
    }

    /// The adapter: a frame built from the contract types. `previousHits` is the counters of the frame before, so
    /// `hits` holds the instruments whose counter moved since then, as `takeHits()` used to.
    public init(sound: SoundFrame, music: MusicContext, previousHits: HitCounters = HitCounters()) {
        let moved = music.hitCounts.delta(since: previousHits)
        self.init(
            spectrum: sound.spectrum, waveform: sound.waveform, wobblePhase: music.wobblePhase,
            wobbleCutoff: music.wobbleCutoff, peakDB: sound.peakDB, rmsDB: sound.rmsDB,
            hits: Set(Instrument.allCases.filter { moved[$0] != 0 }), step: music.step, section: music.section)
    }
}
