import Foundation

/// Timbre features of a stretch of audio, for the samey metric: MFCC means and variances, spectral centroid and
/// spectral flux. 2048-sample Hann frames hopping by 1024 over the mono mix, 26 mel bands from 20 Hz to 16 kHz.
public struct AudioFeatures: Sendable, Hashable, Codable {
    public static let frameSize = 2_048
    public static let hop = 1_024
    public static let melBands = 26
    public static let coefficientCount = 13

    /// Mean of each MFCC over the frames (c0, the log energy, first).
    public var mfccMeans: [Double]
    /// Variance of each MFCC over the frames.
    public var mfccVariances: [Double]
    /// Mean spectral centroid, in Hz.
    public var centroid: Double
    /// Mean spectral flux: the positive change of the normalised magnitude spectrum from frame to frame, 0 ... ~1.
    public var flux: Double

    public init(mfccMeans: [Double], mfccVariances: [Double], centroid: Double, flux: Double) {
        self.mfccMeans = mfccMeans
        self.mfccVariances = mfccVariances
        self.centroid = centroid
        self.flux = flux
    }

    /// Features of `samples` (mono). Fewer samples than one frame give all zeros.
    public static func measure(_ samples: [Float], sampleRate: Double) -> AudioFeatures {
        let n = frameSize
        let bins = n / 2 + 1
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        let filters = melFilters(bins: bins, sampleRate: sampleRate)
        var sums = [Double](repeating: 0, count: coefficientCount)
        var squares = [Double](repeating: 0, count: coefficientCount)
        var centroidSum = 0.0
        var fluxSum = 0.0
        var frames = 0
        var previous: [Double]?
        var real = [Double](repeating: 0, count: n)
        var imaginary = [Double](repeating: 0, count: n)
        var start = 0
        while start + n <= samples.count {
            for i in 0..<n {
                real[i] = Double(samples[start + i]) * window[i]
                imaginary[i] = 0
            }
            FFT.transform(real: &real, imaginary: &imaginary)
            var magnitude = [Double](repeating: 0, count: bins)
            var total = 0.0
            var weighted = 0.0
            for k in 0..<bins {
                magnitude[k] = (real[k] * real[k] + imaginary[k] * imaginary[k]).squareRoot()
                total += magnitude[k]
                weighted += magnitude[k] * Double(k) * sampleRate / Double(n)
            }
            centroidSum += total > 0 ? weighted / total : 0
            let normalised = total > 0 ? magnitude.map { $0 / total } : magnitude
            if let previous {
                var change = 0.0
                for k in 0..<bins { change += max(0, normalised[k] - previous[k]) }
                fluxSum += change
            }
            previous = normalised
            let energies = filters.map { filter in
                var energy = 0.0
                for (bin, weight) in filter { energy += weight * magnitude[bin] * magnitude[bin] }
                return log(energy + 1e-10)
            }
            let mfcc = dct(energies)
            for c in 0..<coefficientCount {
                sums[c] += mfcc[c]
                squares[c] += mfcc[c] * mfcc[c]
            }
            frames += 1
            start += hop
        }
        guard frames > 0 else {
            let zeros = [Double](repeating: 0, count: coefficientCount)
            return AudioFeatures(mfccMeans: zeros, mfccVariances: zeros, centroid: 0, flux: 0)
        }
        let count = Double(frames)
        let means = sums.map { $0 / count }
        let variances = (0..<coefficientCount).map { max(0, squares[$0] / count - means[$0] * means[$0]) }
        return AudioFeatures(
            mfccMeans: means, mfccVariances: variances, centroid: centroidSum / count,
            flux: frames > 1 ? fluxSum / Double(frames - 1) : 0)
    }

    /// Triangular mel filters as (bin, weight) lists.
    static func melFilters(bins: Int, sampleRate: Double) -> [[(Int, Double)]] {
        func mel(_ hz: Double) -> Double { 2_595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2_595) - 1) }
        let low = mel(20)
        let high = mel(min(16_000, sampleRate / 2))
        let edges = (0...(melBands + 1)).map { hz(low + (high - low) * Double($0) / Double(melBands + 1)) }
        let binHz = sampleRate / Double((bins - 1) * 2)
        return (0..<melBands).map { band in
            let (left, centre, right) = (edges[band], edges[band + 1], edges[band + 2])
            var filter: [(Int, Double)] = []
            for k in 0..<bins {
                let f = Double(k) * binHz
                let weight = f < centre ? (f - left) / (centre - left) : (right - f) / (right - centre)
                if weight > 0 { filter.append((k, weight)) }
            }
            return filter
        }
    }

    /// Orthonormal DCT-II of the log mel energies, first `coefficientCount` terms.
    static func dct(_ values: [Double]) -> [Double] {
        let m = Double(values.count)
        return (0..<coefficientCount).map { c in
            var sum = 0.0
            for (i, value) in values.enumerated() {
                sum += value * cos(Double.pi * Double(c) * (Double(i) + 0.5) / m)
            }
            return sum * (c == 0 ? (1 / m).squareRoot() : (2 / m).squareRoot())
        }
    }
}

/// An in-place iterative radix-2 FFT; the length must be a power of two.
enum FFT {
    static func transform(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let (stepRe, stepIm) = (cos(angle), sin(angle))
            var start = 0
            while start < n {
                var (wRe, wIm) = (1.0, 0.0)
                for k in 0..<(length / 2) {
                    let a = start + k
                    let b = a + length / 2
                    let tRe = real[b] * wRe - imaginary[b] * wIm
                    let tIm = real[b] * wIm + imaginary[b] * wRe
                    real[b] = real[a] - tRe
                    imaginary[b] = imaginary[a] - tIm
                    real[a] += tRe
                    imaginary[a] += tIm
                    (wRe, wIm) = (wRe * stepRe - wIm * stepIm, wRe * stepIm + wIm * stepRe)
                }
                start += length
            }
            length <<= 1
        }
    }
}
