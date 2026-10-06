import Foundation

/// Peak and RMS of a block of samples, in dBFS.
public enum Loudness {
    public static let silenceDB: Float = -120

    /// 20 log10 of a linear amplitude; anything at or below 1e-6 reads as silence.
    @inlinable public static func decibels(_ amplitude: Float) -> Float {
        amplitude > 1e-6 ? 20 * log10f(amplitude) : silenceDB
    }

    /// Peak and RMS over the last `window` samples of `samples` (all of them when shorter).
    public static func measure(_ samples: UnsafeBufferPointer<Float>, window: Int? = nil) -> (
        peakDB: Float, rmsDB: Float
    ) {
        let count = min(max(window ?? samples.count, 0), samples.count)
        guard count > 0 else { return (silenceDB, silenceDB) }
        var peak: Float = 0
        var sum: Float = 0
        for i in (samples.count - count)..<samples.count {
            let x = samples[i]
            peak = max(peak, abs(x))
            sum += x * x
        }
        return (decibels(peak), decibels((sum / Float(count)).squareRoot()))
    }
}
