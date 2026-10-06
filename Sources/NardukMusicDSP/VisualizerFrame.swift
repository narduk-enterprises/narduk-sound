import NardukMusicCore

// MARK: - Visualizer feed

/// Audio analysis the engine publishes for the visualizers (~60 Hz), off the render thread.
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
}
