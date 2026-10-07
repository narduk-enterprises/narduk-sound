import Foundation

#if canImport(Accelerate)
    import Accelerate
#endif

/// 2048-point Hann-windowed FFT folded into 64 log-spaced bands (20 Hz – 16 kHz),
/// dB-normalized to 0 ... 1 with fast-attack / slow-release smoothing. Not thread-safe:
/// own one per consumer (the engine runs it on the main actor at ~60 Hz). Uses vDSP where Accelerate exists and a
/// portable radix-2 FFT elsewhere (Linux); both produce the same band layout and scaling.
public final class SpectrumAnalyzer {
    public static let fftSize = 2_048
    public static let bandCount = 64
    public static let lowFrequency: Double = 20
    public static let highFrequency: Double = 16_000
    /// The dB range mapped onto 0 ... 1.
    public static let floorDB: Float = -72

    public let sampleRate: Double
    public private(set) var bands: [Float]
    /// Pitch-class energy of the last `process`, 0 ... 1 (index 0 = C ... 11 = B); see `SoundFrame.chroma`.
    public private(set) var chroma = [Float](repeating: 0, count: SoundFrame.chromaCount)
    /// Where chroma folding starts and stops: below ~80 Hz a bin is wider than a semitone, above ~4 kHz the energy is
    /// overtones and noise.
    public static let chromaLowFrequency: Double = 80
    public static let chromaHighFrequency: Double = 4_000
    public var attack: Float = 0.65
    public var release: Float = 0.12

    #if canImport(Accelerate)
        private let log2n: vDSP_Length
        private let setup: FFTSetup
    #else
        private let fft: PortableFFT
    #endif
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let bandLow: [Int]
    private let bandHigh: [Int]
    private let bandCenter: [Float]
    private let chromaFirstBin: Int
    private let chromaLastBin: Int
    private let chromaSums = UnsafeMutablePointer<Float>.allocate(capacity: SoundFrame.chromaCount)

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let n = SpectrumAnalyzer.fftSize
        let half = n / 2
        window = .allocate(capacity: n)
        #if canImport(Accelerate)
            log2n = vDSP_Length(log2(Double(n)))
            guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                fatalError("vDSP_create_fftsetup failed for a 2048-point FFT")
            }
            setup = fft
            vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        #else
            fft = PortableFFT(size: n)
            // vDSP_HANN_NORM: 0.5 * (1 - cos(2 pi i / N)).
            for i in 0..<n { window[i] = Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(n)))) }
        #endif
        windowed = .allocate(capacity: n)
        windowed.initialize(repeating: 0, count: n)
        real = .allocate(capacity: half)
        real.initialize(repeating: 0, count: half)
        imag = .allocate(capacity: half)
        imag.initialize(repeating: 0, count: half)
        magnitudes = .allocate(capacity: half)
        magnitudes.initialize(repeating: 0, count: half)
        bands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)

        let binHz = sampleRate / Double(n)
        let ratio = SpectrumAnalyzer.highFrequency / SpectrumAnalyzer.lowFrequency
        var lows: [Int] = []
        var highs: [Int] = []
        var centers: [Float] = []
        for i in 0..<SpectrumAnalyzer.bandCount {
            let lo = SpectrumAnalyzer.lowFrequency * pow(ratio, Double(i) / Double(SpectrumAnalyzer.bandCount))
            let hi = SpectrumAnalyzer.lowFrequency * pow(ratio, Double(i + 1) / Double(SpectrumAnalyzer.bandCount))
            lows.append(min(max(Int((lo / binHz).rounded(.up)), 1), half - 1))
            highs.append(min(max(Int((hi / binHz).rounded(.down)), 1), half - 1))
            centers.append(Float(sqrt(lo * hi) / binHz))
        }
        bandLow = lows
        bandHigh = highs
        bandCenter = centers
        chromaFirstBin = max(Int((SpectrumAnalyzer.chromaLowFrequency / binHz).rounded(.up)), 1)
        chromaLastBin = min(Int((SpectrumAnalyzer.chromaHighFrequency / binHz).rounded(.down)), half - 2)
        chromaSums.initialize(repeating: 0, count: SoundFrame.chromaCount)
    }

    deinit {
        #if canImport(Accelerate)
            vDSP_destroy_fftsetup(setup)
        #endif
        window.deallocate()
        windowed.deallocate()
        real.deallocate()
        imag.deallocate()
        magnitudes.deallocate()
        chromaSums.deallocate()
    }

    /// The center frequency of `band` in Hz.
    public func centerFrequency(ofBand band: Int) -> Double {
        Double(bandCenter[band]) * sampleRate / Double(SpectrumAnalyzer.fftSize)
    }

    /// Analyzes the most recent `fftSize` samples (oldest first; shorter input is zero-padded
    /// at the front) and returns the smoothed bands.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        let n = SpectrumAnalyzer.fftSize
        let half = n / 2
        let count = min(samples.count, n)
        let pad = n - count
        for i in 0..<pad { windowed[i] = 0 }
        #if canImport(Accelerate)
            if let base = samples.baseAddress {
                vDSP_vmul(base + (samples.count - count), 1, window + pad, 1, windowed + pad, 1, vDSP_Length(count))
            }
            var split = DSPSplitComplex(realp: real, imagp: imag)
            windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            imag[0] = 0  // packed Nyquist term
            vDSP_zvabs(&split, 1, magnitudes, 1, vDSP_Length(half))
            // zrip returns 2x the DFT; a Hann window halves a sine's peak: amplitude = |X| * 2 / N.
            var scale = Float(2) / Float(n)
            vDSP_vsmul(magnitudes, 1, &scale, magnitudes, 1, vDSP_Length(half))
        #else
            if let base = samples.baseAddress {
                let start = base + (samples.count - count)
                for i in 0..<count { windowed[pad + i] = start[i] * window[pad + i] }
            }
            fft.magnitudes(of: windowed, into: magnitudes)
            // Match vDSP's zrip scaling (2x the DFT), then amplitude = |X| * 2 / N.
            let scale = Float(4) / Float(n)
            for k in 0..<half { magnitudes[k] *= scale }
        #endif

        let floor = SpectrumAnalyzer.floorDB
        for b in 0..<SpectrumAnalyzer.bandCount {
            var amplitude: Float = 0
            if bandLow[b] <= bandHigh[b] {
                for k in bandLow[b]...bandHigh[b] where magnitudes[k] > amplitude { amplitude = magnitudes[k] }
            } else {
                let x = bandCenter[b]
                let k = min(max(Int(x), 1), half - 2)
                let frac = x - Float(k)
                amplitude = magnitudes[k] + (magnitudes[k + 1] - magnitudes[k]) * frac
            }
            let level = min(max((Loudness.decibels(amplitude) - floor) / -floor, 0), 1)
            let previous = bands[b]
            bands[b] = previous + (level - previous) * (level > previous ? attack : release)
        }
        foldChroma(attack: attack, release: release)
        return bands
    }

    /// Folds the spectrum into 12 pitch classes. Each spectral peak is placed at its true frequency (a parabola through
    /// the log magnitudes of the peak bin and its neighbors, since a bin is wider than a semitone below ~300 Hz) and
    /// lends its magnitude to that frequency's class; a class takes its strongest peak, so a wide low-register
    /// partial cannot outweigh a narrow high one. The classes are then scaled so the strongest is 1, gated by how
    /// loud that strongest one is, and smoothed like the bands.
    private func foldChroma(attack: Float, release: Float) {
        let classCount = SoundFrame.chromaCount
        for c in 0..<classCount { chromaSums[c] = 0 }
        let binHz = Float(sampleRate / Double(SpectrumAnalyzer.fftSize))
        if chromaFirstBin <= chromaLastBin {
            for k in chromaFirstBin...chromaLastBin {
                let m = magnitudes[k]
                guard m > 1e-6, m > magnitudes[k - 1], m >= magnitudes[k + 1] else { continue }
                let alpha = logf(max(magnitudes[k - 1], 1e-9))
                let beta = logf(m)
                let gamma = logf(max(magnitudes[k + 1], 1e-9))
                let curvature = alpha - 2 * beta + gamma
                let offset = curvature < -1e-6 ? min(max(0.5 * (alpha - gamma) / curvature, -0.5), 0.5) : 0
                let frequency = (Float(k) + offset) * binHz
                let midi = 69 + 12 * log2f(frequency / 440)
                let pitchClass = ((Int(midi.rounded()) % 12) + 12) % 12
                if m > chromaSums[pitchClass] { chromaSums[pitchClass] = m }
            }
        }
        var strongest: Float = 0
        for c in 0..<classCount where chromaSums[c] > strongest { strongest = chromaSums[c] }
        let floor = SpectrumAnalyzer.floorDB
        let gate = min(max((Loudness.decibels(strongest) - floor) / -floor, 0), 1)
        for c in 0..<classCount {
            let level = strongest > 0 ? chromaSums[c] / strongest * gate : 0
            let previous = chroma[c]
            chroma[c] = previous + (level - previous) * (level > previous ? attack : release)
        }
    }

    /// Forgets the smoothing history: the next `process` starts from silence.
    public func reset() {
        for b in 0..<bands.count { bands[b] = 0 }
        for c in 0..<chroma.count { chroma[c] = 0 }
    }

    public func process(_ samples: [Float]) -> [Float] {
        samples.withUnsafeBufferPointer { process($0) }
    }
}

#if !canImport(Accelerate)
    /// An in-place iterative radix-2 FFT over preallocated buffers, for hosts without Accelerate.
    final class PortableFFT {
        let size: Int
        private let re: UnsafeMutablePointer<Double>
        private let im: UnsafeMutablePointer<Double>
        private let cosTable: UnsafeMutablePointer<Double>
        private let sinTable: UnsafeMutablePointer<Double>
        private let bitReverse: UnsafeMutablePointer<Int>

        init(size: Int) {
            precondition(size > 1 && size & (size - 1) == 0, "PortableFFT needs a power-of-two size")
            self.size = size
            re = .allocate(capacity: size)
            im = .allocate(capacity: size)
            cosTable = .allocate(capacity: size / 2)
            sinTable = .allocate(capacity: size / 2)
            bitReverse = .allocate(capacity: size)
            for k in 0..<(size / 2) {
                let angle = -2 * Double.pi * Double(k) / Double(size)
                cosTable[k] = cos(angle)
                sinTable[k] = sin(angle)
            }
            var bits = 0
            while 1 << bits < size { bits += 1 }
            for i in 0..<size {
                var reversed = 0
                for b in 0..<bits where i & (1 << b) != 0 { reversed |= 1 << (bits - 1 - b) }
                bitReverse[i] = reversed
            }
        }

        deinit {
            re.deallocate()
            im.deallocate()
            cosTable.deallocate()
            sinTable.deallocate()
            bitReverse.deallocate()
        }

        /// |X_k| for k in 0 ..< size / 2 of a real input of `size` samples.
        func magnitudes(of input: UnsafeMutablePointer<Float>, into output: UnsafeMutablePointer<Float>) {
            for i in 0..<size {
                re[bitReverse[i]] = Double(input[i])
                im[bitReverse[i]] = 0
            }
            var length = 2
            while length <= size {
                let halfLength = length / 2
                let stride = size / length
                var start = 0
                while start < size {
                    for k in 0..<halfLength {
                        let wr = cosTable[k * stride]
                        let wi = sinTable[k * stride]
                        let a = start + k
                        let b = a + halfLength
                        let tr = re[b] * wr - im[b] * wi
                        let ti = re[b] * wi + im[b] * wr
                        re[b] = re[a] - tr
                        im[b] = im[a] - ti
                        re[a] += tr
                        im[a] += ti
                    }
                    start += length
                }
                length *= 2
            }
            for k in 0..<(size / 2) { output[k] = Float((re[k] * re[k] + im[k] * im[k]).squareRoot()) }
        }
    }
#endif
