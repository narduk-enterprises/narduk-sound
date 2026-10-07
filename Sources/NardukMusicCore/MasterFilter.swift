import Foundation

/// The master filter's setting: a high-pass and a low-pass over the whole mix, ahead of the limiter. `idle` leaves the
/// mix untouched (the filter is bypassed, bit for bit); anything else sweeps. `DropArranger.filterSweep` writes the
/// rising high-pass of a DROP's build.
public struct MasterFilter: Sendable, Hashable {
    /// Below these the high-pass is open; above these the low-pass is open.
    public static let highPassOpen: Float = 20
    public static let lowPassOpen: Float = 20_000
    public static let idle = MasterFilter()

    /// Hz: what is below this is cut (20 or less is open).
    public var highPassHz: Float
    /// Hz: what is above this is cut (20 000 or more is open).
    public var lowPassHz: Float
    /// 0 ... 1: how much both filters ring at their cutoff.
    public var resonance: Float

    public init(highPassHz: Float = highPassOpen, lowPassHz: Float = lowPassOpen, resonance: Float = 0.2) {
        self.highPassHz = highPassHz.isFinite ? min(max(highPassHz, Self.highPassOpen), 18_000) : Self.highPassOpen
        self.lowPassHz = lowPassHz.isFinite ? min(max(lowPassHz, 60), Self.lowPassOpen) : Self.lowPassOpen
        self.resonance = resonance.isFinite ? min(max(resonance, 0), 0.9) : 0.2
    }

    /// True when both filters are open: the mix passes untouched.
    public var isIdle: Bool { highPassHz <= Self.highPassOpen * 1.01 && lowPassHz >= Self.lowPassOpen * 0.99 }
}
