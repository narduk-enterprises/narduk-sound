import Foundation

/// The photosensitivity limits for the intense visualizers. The main consumer is a children's app, so a full-screen
/// flash is rationed (WCAG 2.3.1: no more than three flashes in any one second) and a saturated red is never flashed.
/// Pure Swift, so the limits are tested on every host, Metal or not.
public struct IntenseFlashLimiter: Sendable {
    /// At most this many flashes start in any rolling second.
    public static let maxFlashesPerSecond = 3
    /// A flash is never brighter than this fraction of full white.
    public static let maxLevel: Float = 0.55
    /// Demand at or above `rise` starts a flash; it ends when demand falls below `fall`.
    static let rise: Float = 0.35
    static let fall: Float = 0.15

    /// When the last three flashes began (a ring, so the fourth must wait for the first to age a second).
    private var onsetA = -Double.infinity
    private var onsetB = -Double.infinity
    private var onsetC = -Double.infinity
    private var oldest = 0
    private var open = false

    public init() {}

    /// The flash level to draw for a raw `demand` (0 ... 1) at `now` seconds. `calm` draws none. A flash that was
    /// refused stays refused until the demand falls and rises again.
    public mutating func limit(_ demand: Float, now: Double, calm: Bool) -> Float {
        if calm {
            open = false
            return 0
        }
        if open {
            if demand < Self.fall { open = false }
        } else if demand >= Self.rise, now - onset(oldest) >= 1.0 {
            setOnset(oldest, now)
            oldest = (oldest + 1) % Self.maxFlashesPerSecond
            open = true
        }
        return open ? min(max(demand, 0), Self.maxLevel) : 0
    }

    private func onset(_ slot: Int) -> Double { slot == 0 ? onsetA : (slot == 1 ? onsetB : onsetC) }

    private mutating func setOnset(_ slot: Int, _ time: Double) {
        switch slot {
        case 0: onsetA = time
        case 1: onsetB = time
        default: onsetC = time
        }
    }

    /// The colour to flash for `color`, with red held below a ratio of the colour's total so a hard red is never
    /// drawn: green and blue are lifted to a third of red when red dominates.
    public static func safeFlashColor(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let lift = color.x / 3
        return SIMD3(color.x, max(color.y, lift), max(color.z, lift))
    }
}

/// What the intense shaders take beyond the state's own envelopes: the rationed flash, the calm scale, the glitch.
public struct IntenseDrive: Sendable, Equatable {
    /// The limited full-screen flash and laser strobe, 0 ... `IntenseFlashLimiter.maxLevel`.
    public var flash: Float = 0
    /// 1 normally; `calmIntensity` in calm, scaling motion, beam sweep and streak length.
    public var intensity: Float = 1
    /// 0 ... 1 glitch strength (RGB split, tearing, block shifts); 0 in calm.
    public var glitch: Float = 0
    /// The flash tint: the palette's third colour pulled halfway to white, then made red-safe.
    public var flashColor = SIMD3<Float>(1, 1, 1)

    public static let calmIntensity: Float = 0.4

    public init() {}

    /// Computes the drive from the raw envelopes. `limiter` carries the flash history between frames.
    public init(
        flashDemand: Float, glitchDemand: Float, tint: SIMD3<Float>, calm: Bool, now: Double,
        limiter: inout IntenseFlashLimiter
    ) {
        flash = limiter.limit(flashDemand, now: now, calm: calm)
        intensity = calm ? Self.calmIntensity : 1
        glitch = calm ? 0 : min(max(glitchDemand, 0), 1)
        let white = SIMD3<Float>(repeating: 1)
        flashColor = IntenseFlashLimiter.safeFlashColor(tint + (white - tint) * 0.5)
    }
}

extension IntenseDrive {
    /// The drive for `state`'s current picture: a snare on the drop and the state's own flash ask for a flash, and
    /// the glitch follows the state's glitch envelope and the drop.
    @MainActor public init(state: SoundVisualState, limiter: inout IntenseFlashLimiter) {
        self.init(
            flashDemand: max(state.flash, state.snare * state.dropAmount),
            glitchDemand: max(state.glitch, state.dropAmount * 0.55 + state.snare * 0.35),
            tint: state.palette.c2, calm: state.calm, now: state.time, limiter: &limiter)
    }
}

/// The intense visualizers (narduk-libs#1615).
public enum IntenseKind: String, Sendable, CaseIterable, Hashable {
    case hyperspaceLasers, fluidGlitch
    /// A Mandelbrot dive: bass pushes the zoom, section changes turn the picture and shift the colour.
    case fractalDive
    /// A neon grid terrain under a striped sun: the spectrum raises the hills, the drop lifts off.
    case synthwaveFlyover

    public var title: String {
        switch self {
        case .hyperspaceLasers: "Hyperspace + lasers"
        case .fluidGlitch: "Fluid + glitch"
        case .fractalDive: "Fractal dive"
        case .synthwaveFlyover: "Synthwave flyover"
        }
    }
}
