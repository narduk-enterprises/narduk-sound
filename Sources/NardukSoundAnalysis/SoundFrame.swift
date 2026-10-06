/// What any sound is doing, ~60 Hz. Every visualizer must work from this alone.
///
/// Poll frames on the visualizer's own clock (`TimelineView` / `MTKView`); never observe them. `sequence` says
/// whether a poll returned a new frame without comparing the arrays.
public struct SoundFrame: Sendable, Hashable {
    public static let spectrumCount = SpectrumAnalyzer.bandCount
    public static let waveformCount = 512
    /// The level reported for silence, in dBFS.
    public static let silenceDB: Float = Loudness.silenceDB

    /// Increases by one for every new analysis a source produces. 0 is the empty frame before any analysis.
    public var sequence: UInt64
    /// Seconds on the source's clock (the caller's, for sources that are polled with a time).
    public var time: Double
    /// Log-spaced magnitude bands, 0 ... 1 (64 bands, 20 Hz – 16 kHz).
    public var spectrum: [Float]
    /// The latest waveform, mono, -1 ... 1 (512 samples, oldest first).
    public var waveform: [Float]
    /// Peak and RMS over the most recent analysis window, in dBFS (silence is -120).
    public var peakDB: Float
    public var rmsDB: Float

    public init(
        sequence: UInt64 = 0, time: Double = 0,
        spectrum: [Float] = Array(repeating: 0, count: SoundFrame.spectrumCount),
        waveform: [Float] = Array(repeating: 0, count: SoundFrame.waveformCount),
        peakDB: Float = SoundFrame.silenceDB, rmsDB: Float = SoundFrame.silenceDB
    ) {
        self.sequence = sequence
        self.time = time
        self.spectrum = spectrum
        self.waveform = waveform
        self.peakDB = peakDB
        self.rmsDB = rmsDB
    }
}
