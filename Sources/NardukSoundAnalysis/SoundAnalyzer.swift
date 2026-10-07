import Foundation

/// Turns the most recent samples of any mono audio into a `SoundFrame`: spectrum, waveform and loudness. Not
/// thread-safe: own one per consumer and call it off the audio thread (the visualizer's clock, ~60 Hz).
public final class SoundAnalyzer {
    /// How many trailing samples one analysis reads.
    public static let windowSize = SpectrumAnalyzer.fftSize

    public let sampleRate: Double
    /// The trailing samples peak and RMS are measured over (one display frame by default).
    public let loudnessWindow: Int
    public private(set) var sequence: UInt64 = 0
    private let spectrumAnalyzer: SpectrumAnalyzer

    public init(sampleRate: Double, loudnessSeconds: Double = 1.0 / 60) {
        self.sampleRate = sampleRate
        loudnessWindow = min(max(Int(sampleRate * loudnessSeconds), 1), SoundAnalyzer.windowSize)
        spectrumAnalyzer = SpectrumAnalyzer(sampleRate: sampleRate)
    }

    /// Analyzes `samples` (oldest first; the last `windowSize` are used, shorter input is front-padded with
    /// silence) and returns the next frame.
    public func analyze(_ samples: UnsafeBufferPointer<Float>, time: Double) -> SoundFrame {
        sequence &+= 1
        let spectrum = spectrumAnalyzer.process(samples)
        let (peak, rms) = Loudness.measure(samples, window: loudnessWindow)
        var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
        let copied = min(samples.count, waveform.count)
        for i in 0..<copied { waveform[waveform.count - copied + i] = samples[samples.count - copied + i] }
        return SoundFrame(
            sequence: sequence, time: time, spectrum: spectrum, waveform: waveform, peakDB: peak, rmsDB: rms,
            chroma: spectrumAnalyzer.chroma)
    }

    public func analyze(_ samples: [Float], time: Double) -> SoundFrame {
        samples.withUnsafeBufferPointer { analyze($0, time: time) }
    }

    /// Clears the spectrum smoothing and the sequence, as if newly created.
    public func reset() {
        sequence = 0
        spectrumAnalyzer.reset()
    }
}
