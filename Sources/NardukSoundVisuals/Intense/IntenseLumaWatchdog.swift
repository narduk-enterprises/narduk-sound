import Foundation

/// A runtime guard for plugin visualizers (narduk-libs#1665). `IntenseFlashLimiter` rations only the flash the app
/// hands a shader; a plugin can strobe on its own. The watchdog watches a tile's frame-to-frame mean luma (0 ... 1)
/// and, when the picture jumps up by more than `jump` more than `maxPerSecond` times in a second (the A11 numbers:
/// WCAG 2.3.1), dims the tile until it has been calm for `hold` seconds. The dim is a gain on the finished picture,
/// so it works on any shader. Pure Swift, so the rule is tested on every host.
public struct IntenseLumaWatchdog: Sendable {
    public static let jump: Float = 0.3
    public static let maxPerSecond = 3
    /// The gain while tripped: a 0.8 swing of strobe becomes 0.2, under `jump`.
    public static let dimmedGain: Float = 0.25
    /// Seconds the dim holds after the last offending jump.
    public static let hold: Double = 1.5

    private var last: Float = -1
    private var lastTime: Double = -.infinity
    /// When the last four offending rises happened (a ring); four inside one second is more than three a second.
    private var rises: (Double, Double, Double, Double) = (-.infinity, -.infinity, -.infinity, -.infinity)
    private var next = 0
    private var dimUntil = -Double.infinity
    /// The gain to draw with, 1 (untouched) ... `dimmedGain`.
    public private(set) var gain: Float = 1
    public private(set) var isDimming = false

    public init() {}

    /// Feeds the latest measured `luma` at `time` seconds and returns the gain for the next frame. A repeated time
    /// changes nothing.
    @discardableResult
    public mutating func observe(luma: Float, time: Double) -> Float {
        guard time > lastTime else { return gain }
        let dt = Float(min(time - lastTime, 0.25))
        lastTime = time
        defer { last = luma }
        if last >= 0, luma - last > Self.jump {
            setRise(next, time)
            next = (next + 1) % 4
            // Not 1.0: exactly three a second is allowed, and frame times are floats.
            if time - oldestRise < 0.99 { dimUntil = time + Self.hold }
        }
        isDimming = time < dimUntil
        // Ease in fast (a strobe must be tamed within a frame or two), out slowly.
        let target = isDimming ? Self.dimmedGain : 1
        let rate: Float = isDimming ? 30 : 2
        gain += (target - gain) * min(1, dt * rate)
        return gain
    }

    /// The oldest of the four stored rises: the slot `next` is about to overwrite.
    private var oldestRise: Double {
        switch next {
        case 0: rises.0
        case 1: rises.1
        case 2: rises.2
        default: rises.3
        }
    }

    private mutating func setRise(_ slot: Int, _ time: Double) {
        switch slot {
        case 0: rises.0 = time
        case 1: rises.1 = time
        case 2: rises.2 = time
        default: rises.3 = time
        }
    }
}
