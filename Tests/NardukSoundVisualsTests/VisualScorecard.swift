import Foundation
import NardukMusicCore
import NardukSoundAnalysis

@testable import NardukSoundVisuals

/// The visualizer scorecard's numbers (docs/visual-scorecard.md): pure functions over per-frame series, so the maths is
/// unit-tested without a GPU. Measure only: nothing here changes how a visualizer looks.
enum VisualScorecard {
    static let fps = 60.0

    /// One rendered frame, reduced to scalars.
    struct Frame {
        var luma: Float  // mean luma, 0 ... 1
        var spread: Float  // p90 - p10 of the pixel luma, 0 ... 1
        var motion: Float  // mean absolute RGB change from the previous frame, 0 ... 1
        var hue: Float  // hue of the mean colour, 0 ... 1 (0 when grey)
        var saturation: Float
    }

    /// What the music did in the same frame.
    struct Input {
        var rmsDB: Float
        var kick: Bool
        var snare: Bool
    }

    /// Every number for one (song, transform, visualizer).
    struct Metrics {
        var frames = 0
        var luma = (p10: Double.nan, p50: Double.nan, p90: Double.nan)
        var spread = (p10: Double.nan, p50: Double.nan, p90: Double.nan)
        var kickHits = 0
        var kickRatio = Double.nan
        var kickLagMS = Double.nan
        var snareHits = 0
        var snareRatio = Double.nan
        var snareLagMS = Double.nan
        var rmsLumaCorrelation = Double.nan
        var rmsMotionCorrelation = Double.nan
        var sectionMotionRatio = Double.nan
        var sectionLumaRatio = Double.nan
        var frozenShare = Double.nan
        var motionP50 = Double.nan
        var motionP99 = Double.nan
    }

    /// Motion below this (mean absolute change, 0 ... 1; about 0.05 of one 8-bit level) counts as a frozen frame.
    static let frozenMotion = 2e-4
    /// The reaction window after a hit, and how far the lag search looks.
    static let hitWindowFrames = 6  // frames 0 ... 6 after the hit frame = 0 ... 100 ms
    static let lagSearchFrames = 18  // 300 ms
    static let smoothingFrames = 30  // 0.5 s
    static let sectionFrames = 120  // 2 s
    static let minimumHits = 3

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count)
    }

    /// A centred box mean of `width` samples, shorter at the edges.
    static func smooth(_ values: [Double], width: Int) -> [Double] {
        guard width > 1, !values.isEmpty else { return values }
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for (i, v) in values.enumerated() { prefix[i + 1] = prefix[i] + v }
        let half = width / 2
        return (0..<values.count).map { i in
            let a = max(i - half, 0)
            let b = min(i + half + 1, values.count)
            return (prefix[b] - prefix[a]) / Double(b - a)
        }
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 2 else { return .nan }
        let mx = mean(x)
        let my = mean(y)
        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for i in 0..<x.count {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
        }
        // A flat series has no correlation to report (not zero: it never moved).
        guard sxx > 1e-18, syy > 1e-18 else { return .nan }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Frames where a hit counter rose.
    static func hitFrames(_ flags: [Bool]) -> [Int] { flags.indices.filter { flags[$0] } }

    /// The mean motion in the 0 ... 100 ms after each hit over the mean motion elsewhere, and the lag (ms) at which
    /// the hit-aligned mean motion peaks within 300 ms. NaN when fewer than `minimumHits` hits.
    static func hitResponse(motion: [Double], hits: [Int]) -> (ratio: Double, lagMS: Double) {
        guard hits.count >= minimumHits, !motion.isEmpty else { return (.nan, .nan) }
        var inside = [Bool](repeating: false, count: motion.count)
        for hit in hits {
            for f in hit...min(hit + hitWindowFrames, motion.count - 1) { inside[f] = true }
        }
        var near = 0.0
        var far = 0.0
        var nearCount = 0
        var farCount = 0
        for (i, m) in motion.enumerated() {
            if inside[i] {
                near += m
                nearCount += 1
            } else {
                far += m
                farCount += 1
            }
        }
        guard nearCount > 0, farCount > 0 else { return (.nan, .nan) }
        let baseline = far / Double(farCount)
        let ratio = (near / Double(nearCount)) / max(baseline, 1e-9)
        // The hit-aligned mean curve, over the hits with the whole search range inside the series.
        var curve = [Double](repeating: 0, count: lagSearchFrames + 1)
        var used = 0
        for hit in hits where hit + lagSearchFrames < motion.count {
            for k in 0...lagSearchFrames { curve[k] += motion[hit + k] }
            used += 1
        }
        guard used > 0, let peak = curve.indices.max(by: { curve[$0] < curve[$1] }) else { return (ratio, .nan) }
        return (ratio, Double(peak) * 1000 / fps)
    }

    /// The loudest 20% of 2 s windows against the quietest 20%: mean motion and mean luma ratios.
    static func sectionContrast(rmsDB: [Double], motion: [Double], luma: [Double]) -> (motion: Double, luma: Double) {
        let windows = rmsDB.count / sectionFrames
        guard windows >= 5 else { return (.nan, .nan) }
        func windowMean(_ values: [Double], _ w: Int) -> Double {
            mean(Array(values[(w * sectionFrames)..<((w + 1) * sectionFrames)]))
        }
        let order = (0..<windows).sorted { windowMean(rmsDB, $0) < windowMean(rmsDB, $1) }
        let k = max(1, Int((Double(windows) * 0.2).rounded()))
        let quiet = Array(order.prefix(k))
        let loud = Array(order.suffix(k))
        func ratio(_ values: [Double]) -> Double {
            mean(loud.map { windowMean(values, $0) }) / max(mean(quiet.map { windowMean(values, $0) }), 1e-9)
        }
        return (ratio(motion), ratio(luma))
    }

    static func score(frames: [Frame], inputs: [Input]) -> Metrics {
        var m = Metrics()
        m.frames = frames.count
        guard frames.count == inputs.count, !frames.isEmpty else { return m }
        let luma = frames.map { Double($0.luma) }
        let spread = frames.map { Double($0.spread) }
        let motion = frames.map { Double($0.motion) }
        let rms = inputs.map { Double(max($0.rmsDB, -100)) }
        m.luma = (percentile(luma, 0.1), percentile(luma, 0.5), percentile(luma, 0.9))
        m.spread = (percentile(spread, 0.1), percentile(spread, 0.5), percentile(spread, 0.9))
        let kicks = hitFrames(inputs.map(\.kick))
        let snares = hitFrames(inputs.map(\.snare))
        m.kickHits = kicks.count
        m.snareHits = snares.count
        (m.kickRatio, m.kickLagMS) = hitResponse(motion: motion, hits: kicks)
        (m.snareRatio, m.snareLagMS) = hitResponse(motion: motion, hits: snares)
        let smoothRMS = smooth(rms, width: smoothingFrames)
        m.rmsLumaCorrelation = pearson(smoothRMS, smooth(luma, width: smoothingFrames))
        m.rmsMotionCorrelation = pearson(smoothRMS, smooth(motion, width: smoothingFrames))
        (m.sectionMotionRatio, m.sectionLumaRatio) = sectionContrast(rmsDB: rms, motion: motion, luma: luma)
        m.frozenShare = Double(motion.filter { $0 < frozenMotion }.count) / Double(motion.count)
        m.motionP50 = percentile(motion, 0.5)
        m.motionP99 = percentile(motion, 0.99)
        return m
    }

    /// Plain-language flags for a table row: the quick "what is wrong with this one".
    static func flags(_ m: Metrics) -> String {
        var out: [String] = []
        if m.luma.p90 < 0.04 { out.append("dark") }
        if m.luma.p10 > 0.45 { out.append("bright") }
        if m.spread.p90 - m.spread.p10 < 0.02 && m.spread.p50 < 0.05 { out.append("flat") }
        if m.spread.p10 > 0.35 { out.append("busy") }
        if m.frozenShare > 0.25 { out.append("frozen") }
        if m.motionP99 > 0.12 && m.motionP99 > 6 * max(m.motionP50, 1e-6) { out.append("strobe") }
        let ratios = [m.kickRatio, m.snareRatio].filter { !$0.isNaN }
        if let best = ratios.max(), best < 1.1 { out.append("deaf-to-hits") }
        if m.rmsMotionCorrelation < 0.1 && m.rmsLumaCorrelation < 0.1 { out.append("ignores-loudness") }
        return out.joined(separator: " ")
    }

    // MARK: Window choice

    /// The start (seconds) of the `seconds`-long window of the timeline with the widest loudness range: the p90 - p10 of
    /// the 1 s smoothed rms (dB, floored at -40, so a silent lead-in does not count as the quiet part). Starts every
    /// 2.5 s, at least `margin` seconds from either end of the song (the fade-in and the fade-out are not the song).
    static func chooseWindow(rmsDB: [Double], gridRate: Double, seconds: Double, margin: Double = 10) -> Double {
        let length = Int(seconds * gridRate)
        guard rmsDB.count > length + 1 else { return 0 }
        let smoothed = smooth(rmsDB.map { max($0, -40) }, width: Int(gridRate))
        let duration = Double(smoothed.count) / gridRate
        var best = (start: 0.0, spread: -Double.infinity)
        var start = duration >= seconds + 2 * margin ? margin : 0
        let last = duration >= seconds + 2 * margin ? duration - margin - seconds : duration - seconds - 1
        while start <= last, Int((start + seconds) * gridRate) < smoothed.count {
            let a = Int(start * gridRate)
            let slice = Array(smoothed[a..<(a + length)])
            let spread = percentile(slice, 0.9) - percentile(slice, 0.1)
            if spread > best.spread { best = (start, spread) }
            start += 2.5
        }
        return best.start
    }

    // MARK: Input transforms

    /// Applied to each `SoundVisualInput` before the visualizer sees it. Scoring reads rms and hits from the raw
    /// input, so a transform changes the picture and not the yardstick.
    typealias Transform = @Sendable (SoundVisualInput) -> SoundVisualInput

    static let identity: Transform = { $0 }

    /// A per-band rescale of the spectrum: each band's p5 maps to 0 and its p98 to 1 (clamped), taken over the whole
    /// song. A stand-in for the per-song contrast normalisation an app would ship.
    static func rescale(_ timeline: SoundTimeline) -> Transform {
        let bands = SoundTimeline.bandCount
        let n = timeline.sampleCount
        var low = [Float](repeating: 0, count: bands)
        var span = [Float](repeating: 1, count: bands)
        for b in 0..<bands {
            let values = (0..<n).map { Double(timeline.spectrum[$0 * bands + b]) / 255 }
            let lo = percentile(values, 0.05)
            let hi = percentile(values, 0.98)
            low[b] = Float(lo)
            span[b] = Float(max(hi - lo, 1.0 / 255))
        }
        let lows = low
        let spans = span
        return { input in
            var out = input
            for b in 0..<min(bands, out.frame.spectrum.count) {
                out.frame.spectrum[b] = min(max((out.frame.spectrum[b] - lows[b]) / spans[b], 0), 1)
            }
            return out
        }
    }

    static func hueSaturation(r: Double, g: Double, b: Double) -> (hue: Float, saturation: Float) {
        let high = max(r, g, b)
        let low = min(r, g, b)
        let delta = high - low
        guard delta > 1e-6 else { return (0, 0) }
        var h: Double
        if high == r {
            h = (g - b) / delta
        } else if high == g {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }
        h /= 6
        if h < 0 { h += 1 }
        return (Float(h), Float(delta / high))
    }
}
