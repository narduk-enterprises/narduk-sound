import Foundation

/// One column of a stream, analysed online: what a whole-file analysis (range, rolling mean and spread, peaks,
/// anomalies) gives a sonifier, but causal (it only looks back) and bounded (a fixed window), so it runs forever at O(1) per sample plus a periodic window sort.
///
/// Batch → online: global min/max → percentiles of the recent window; rolling mean/std → time-based EWMAs;
/// peaks found with a symmetric window → peaks confirmed `lag` samples late; global anomaly z → z against the EWMA.
public struct OnlineSeries: Sendable {
    public let name: String
    /// Samples kept for the range (decimated so they span `span` seconds whatever the rate).
    public let window: Int
    /// Seconds the robust range covers.
    public let span: Double
    /// Seconds the smoothed value (the tune) averages over.
    public let smoothing: Double
    /// Seconds the running mean and spread remember (the "neighbourhood" for z-scores and crossings).
    public let memory: Double

    public private(set) var count = 0
    public private(set) var value = 0.0
    /// Smoothed value.
    public private(set) var smooth = 0.0
    public private(set) var mean = 0.0
    public private(set) var variance = 0.0
    /// Robust (2nd ... 98th percentile) range of the window, eased so the scale does not lurch.
    public private(set) var range: ClosedRange<Double> = 0...1
    /// The last few smoothed values, for peaks and troughs.
    private var recent: [Double] = []
    /// Smoothed values over the last `span` seconds, decimated to at most `window`, for the range.
    private var history: [Double] = []
    /// Copy of `history` the percentile selection reorders in place, so the periodic range refresh never allocates.
    private var scratch: [Double] = []
    private var sinceKept = 0
    private var lastTime: Double?
    private var deltaScale = 0.0
    private var rate = 0.0
    private var runUp = 0
    private var inAnomaly = false
    private var lastSide: Bool?

    public init(name: String, window: Int = 2048, span: Double = 60, smoothing: Double = 0.2, memory: Double = 20) {
        self.name = name
        self.window = Swift.max(64, window)
        self.span = span
        self.smoothing = smoothing
        self.memory = memory
        // Everything the series ever holds is sized here, so `add` allocates nothing once running.
        recent.reserveCapacity(2 * Self.maxLag + 1 + 64 + 1)
        history.reserveCapacity(self.window + 1)
        scratch.reserveCapacity(self.window + 1)
    }

    public var std: Double { variance.squareRoot() }
    /// The spread z-scores divide by: never under a tenth of the recent range, so a price that moves a cent at a
    /// time does not turn every tick into a 500-sigma anomaly.
    public var scale: Double { Swift.max(variance.squareRoot(), 0.1 * (range.upperBound - range.lowerBound), 1e-12) }
    /// 0 ... 1: where the smoothed value sits in the recent window.
    public var level: Double {
        let span = Swift.max(1e-12, range.upperBound - range.lowerBound)
        return Swift.min(1, Swift.max(0, (smooth - range.lowerBound) / span))
    }
    public var localZ: Double { count > 1 ? (smooth - mean) / scale : 0 }
    /// The tune: half where the value sits in the window, half where it sits in its own neighbourhood (as batch).
    public var melody: Double { 0.55 * level + 0.45 * Swift.min(1, Swift.max(0, 0.5 + localZ / 4)) }
    /// How fast it is moving now against how fast it usually moves, 0 ... 1 (1 = a jump).
    public private(set) var motion = 0.0
    /// The most samples a peak waits for, whatever the rate.
    static let maxLag = 256
    /// Samples a peak is confirmed after (about a quarter second of samples).
    public var lag: Int { Swift.min(Self.maxLag, Swift.max(3, Int(rate * 0.25))) }

    /// What one sample did.
    public struct Change: Sendable {
        public var peak: (index: Int, z: Double)?
        public var trough: (index: Int, z: Double)?
        public var crossed = false
        public var jumped: Bool?
        public var rising = false
        public var anomalyZ: Double?
    }

    public mutating func add(_ x: Double, time: Double) -> Change {
        var change = Change()
        guard x.isFinite else { return change }
        let dt = lastTime.map { Swift.max(0, time - $0) } ?? 0
        lastTime = time
        value = x
        if count == 0 {
            smooth = x
            mean = x
            range = x...(x + 1e-9)
        } else {
            if dt > 0 { rate += (1 / dt - rate) * (rate == 0 ? 1 : 0.05) }
            let fast = 1 - exp(-dt / smoothing)
            let slow = 1 - exp(-dt / memory)
            let previous = smooth
            smooth += fast * (x - smooth)
            let delta = smooth - previous
            let z = count > 1 ? (x - mean) / scale : 0
            let diff = x - mean
            mean += slow * diff
            variance = (1 - slow) * (variance + slow * diff * diff)
            deltaScale += (abs(delta) - deltaScale) * Swift.max(slow, 0.01)
            let speed = deltaScale > 0 ? abs(delta) / (4 * deltaScale) : 0
            let wasJump = motion >= 1
            motion = Swift.min(1, speed)
            if motion >= 1, !wasJump, count > 32 { change.jumped = delta > 0 }
            runUp = delta > 0 ? runUp + 1 : 0
            if runUp == 2 * lag { change.rising = true }
            if abs(z) > 3.5, !inAnomaly, count > 64 {
                change.anomalyZ = z
                inAnomaly = true
            } else if abs(z) < 2 {
                inAnomaly = false
            }
            let side = smooth > mean
            if let lastSide, side != lastSide, count > 32 { change.crossed = true }
            lastSide = side
        }
        if recent.count >= 2 * lag + 1 + 64 { recent.removeFirst(64) }
        recent.append(smooth)
        // Keep every k-th value so the history spans `span` seconds at the current rate.
        sinceKept += 1
        if sinceKept >= Swift.max(1, Int(rate * span / Double(window))) {
            sinceKept = 0
            if history.count == window { history.removeFirst(window / 8) }
            history.append(smooth)
        }
        count += 1
        if count % 32 == 0 || count < 64 { refreshRange() }
        detectTurn(&change)
        return change
    }

    /// The window's 2nd ... 98th percentiles, eased in (a new regime takes a few seconds to own the scale).
    private mutating func refreshRange() {
        guard !history.isEmpty else { return }
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: history)
        let top = scratch.count - 1
        let lo = Self.select(&scratch, Int(Double(top) * 0.02))
        let hi = Swift.max(Self.select(&scratch, Int(Double(top) * 0.98)), lo + 1e-9)
        let ease = count < 256 ? 1 : 0.25
        let lower = range.lowerBound + ease * (lo - range.lowerBound)
        let upper = Swift.max(range.upperBound + ease * (hi - range.upperBound), lower + 1e-9)
        range = lower...upper
    }

    /// The value that sits at `rank` once `values` is sorted (quickselect, median of three), reordering `values` in
    /// place: the same answer as sorting a copy, with no allocation.
    static func select(_ values: inout [Double], _ rank: Int) -> Double {
        var low = 0
        var high = values.count - 1
        while low < high {
            let mid = low + (high - low) / 2
            if values[mid] < values[low] { values.swapAt(mid, low) }
            if values[high] < values[low] { values.swapAt(high, low) }
            if values[high] < values[mid] { values.swapAt(high, mid) }
            let pivot = values[mid]
            var i = low
            var j = high
            while i <= j {
                while values[i] < pivot { i += 1 }
                while values[j] > pivot { j -= 1 }
                if i <= j {
                    values.swapAt(i, j)
                    i += 1
                    j -= 1
                }
            }
            if rank <= j {
                high = j
            } else if rank >= i {
                low = i
            } else {
                return values[rank]
            }
        }
        return values[rank]
    }

    /// A peak (trough) `lag` samples ago: the highest (lowest) smoothed value within `lag` either side, standing out.
    private func detectTurn(_ change: inout Change) {
        let lag = lag
        let n = recent.count
        guard n > 2 * lag, count > 64 else { return }
        let c = n - 1 - lag
        let centre = recent[c]
        var isMax = true
        var isMin = true
        for i in (c - lag)...(c + lag) where i != c {
            if recent[i] >= centre { isMax = false }
            if recent[i] <= centre { isMin = false }
            if !isMax && !isMin { return }
        }
        let z = (centre - mean) / scale
        if isMax, z > 0.5 { change.peak = (count - 1 - lag, z) }
        if isMin, z < -0.5 { change.trough = (count - 1 - lag, z) }
    }
}
