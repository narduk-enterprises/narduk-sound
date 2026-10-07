import Foundation

/// Integrated loudness in LUFS (ITU-R BS.1770-4): K-weighting, 400 ms blocks overlapping by 75 %, an absolute gate at
/// -70 LUFS and a relative gate 10 LU under the ungated level. The A/B harness uses it to loudness-match a pair, so a
/// listener never prefers one clip because it is louder.
public enum IntegratedLoudness {
    /// What a block, or a whole signal, reads when nothing passes the gates.
    public static let silence = -120.0

    /// Integrated loudness of a stereo signal, in LUFS (both channels weighted 1).
    public static func measure(_ audio: RenderedAudio) -> Double {
        measure(channels: [audio.left, audio.right], sampleRate: audio.sampleRate)
    }

    /// Integrated loudness of one or more channels of equal length, in LUFS.
    public static func measure(channels: [[Float]], sampleRate: Double) -> Double {
        let frames = channels.map(\.count).min() ?? 0
        let blockLength = Int(sampleRate * 0.4)
        let hop = Int(sampleRate * 0.1)
        guard frames >= blockLength, blockLength > 0, hop > 0 else { return silence }
        // The K-weighted square of every frame, summed over channels, then one running sum for the blocks.
        var power = [Double](repeating: 0, count: frames)
        for channel in channels {
            var shelf = Biquad.highShelf(sampleRate: sampleRate)
            var highPass = Biquad.highPass(sampleRate: sampleRate)
            for i in 0..<frames {
                let y = highPass.process(shelf.process(Double(channel[i])))
                power[i] += y * y
            }
        }
        var prefix = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { prefix[i + 1] = prefix[i] + power[i] }
        var blocks: [Double] = []
        var start = 0
        while start + blockLength <= frames {
            blocks.append((prefix[start + blockLength] - prefix[start]) / Double(blockLength))
            start += hop
        }
        func lufs(_ meanSquare: Double) -> Double { meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : silence }
        let absolute = blocks.filter { lufs($0) > -70 }
        guard !absolute.isEmpty else { return silence }
        let relativeGate = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return silence }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }

    /// Scales `audio` by `decibels` of gain.
    public static func applying(_ decibels: Double, to audio: RenderedAudio) -> RenderedAudio {
        let gain = Float(pow(10, decibels / 20))
        return RenderedAudio(
            sampleRate: audio.sampleRate, left: audio.left.map { $0 * gain }, right: audio.right.map { $0 * gain })
    }

    /// A pair brought to the same integrated loudness. Only the louder one is turned down, so neither can clip.
    public struct MatchedPair: Sendable {
        public var a: RenderedAudio
        public var b: RenderedAudio
        /// Loudness before matching, in LUFS.
        public var loudnessA: Double
        public var loudnessB: Double
        /// Gain applied to each, in dB (0 or negative).
        public var gainA: Double
        public var gainB: Double
        /// Loudness after matching, measured again, in LUFS.
        public var matchedA: Double
        public var matchedB: Double

        /// How far apart the matched pair reads, in LU.
        public var difference: Double { abs(matchedA - matchedB) }
    }

    /// Turns the louder of `a` and `b` down to the quieter one's integrated loudness, then measures both again.
    public static func match(_ a: RenderedAudio, _ b: RenderedAudio) -> MatchedPair {
        let loudnessA = measure(a)
        let loudnessB = measure(b)
        let target = min(loudnessA, loudnessB)
        let gainA = loudnessA > silence ? target - loudnessA : 0
        let gainB = loudnessB > silence ? target - loudnessB : 0
        let matchedA = gainA == 0 ? a : applying(gainA, to: a)
        let matchedB = gainB == 0 ? b : applying(gainB, to: b)
        return MatchedPair(
            a: matchedA, b: matchedB, loudnessA: loudnessA, loudnessB: loudnessB, gainA: gainA, gainB: gainB,
            matchedA: measure(matchedA), matchedB: measure(matchedB))
    }

    /// A direct-form-I biquad over doubles.
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }

        /// BS.1770 stage 1, the head's high shelf, at any sample rate (the 48 kHz coefficients re-derived).
        static func highShelf(sampleRate: Double) -> Biquad {
            let k = tan(Double.pi * 1_681.974450955533 / sampleRate)
            let q = 0.7071752369554196
            let vh = pow(10, 3.999843853973347 / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            return Biquad(
                b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }

        /// BS.1770 stage 2, the RLB high-pass.
        static func highPass(sampleRate: Double) -> Biquad {
            let k = tan(Double.pi * 38.13547087602444 / sampleRate)
            let q = 0.5003270373238773
            let a0 = 1 + k / q + k * k
            return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        }
    }
}
