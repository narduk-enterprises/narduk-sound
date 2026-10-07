import Foundation

/// Keeps a Metal stage inside its frame budget on slower GPUs. Each finished frame reports its GPU time; twice a second
/// the governor looks at the slow end of the last batch and, when it runs over budget, lowers the render scale (cost
/// follows pixel count, so a scale of 0.3 is about six times cheaper than 0.75), then halves the frame rate if the
/// smallest scale is still too slow. It climbs back slowly when there is headroom, so a fast GPU stays at full quality.
/// Measured on an iPad (10th generation), where 13 of Beat Blaster's 35 lights ran at 5 to 40 fps at a fixed 0.75.
struct SoundRenderGovernor: Equatable {
    static let maxScale = 0.75
    static let minScale = 0.2
    /// Each decision needs this many frames and this much time since the last one.
    static let batch = 12
    static let interval = 0.5

    private(set) var scale = maxScale
    private(set) var halfRate = false
    private var samples: [Double] = []
    private var lastDecision = 0.0

    /// GPU milliseconds a frame may take at the current rate.
    var budgetMs: Double { halfRate ? 1000 / 30 : 1000 / 60 }

    /// Feeds one finished frame; returns true when the scale or the rate changed.
    mutating func observe(gpuMs: Double, at now: Double) -> Bool {
        samples.append(gpuMs)
        guard samples.count >= Self.batch, now - lastDecision >= Self.interval else { return false }
        let sorted = samples.sorted()
        let slow = sorted[(sorted.count * 3) / 4]
        samples.removeAll(keepingCapacity: true)
        lastDecision = now
        let changed = decide(slow: slow)
        // A resize takes a moment to reach the GPU: skip one batch so frames at the old size do not count twice.
        if changed { lastDecision = now + Self.interval }
        return changed
    }

    private mutating func decide(slow: Double) -> Bool {
        let target = budgetMs * 0.8
        if slow > budgetMs {
            if scale > Self.minScale {
                scale = Self.quantized(max(Self.minScale, scale * (target / slow).squareRoot()))
                return true
            }
            if !halfRate {
                halfRate = true
                return true
            }
            return false
        }
        // Headroom: back to full rate first (the GPU time per frame does not change with the rate), then sharper.
        if halfRate, slow < 1000 / 60 * 0.8 {
            halfRate = false
            return true
        }
        if !halfRate, scale < Self.maxScale, slow < target * 0.6 {
            scale = Self.quantized(min(Self.maxScale, scale * 1.15))
            return true
        }
        return false
    }

    /// Steps of 0.05, so tiny swings do not resize the drawable every half second.
    private static func quantized(_ value: Double) -> Double { (value * 20).rounded() / 20 }
}
