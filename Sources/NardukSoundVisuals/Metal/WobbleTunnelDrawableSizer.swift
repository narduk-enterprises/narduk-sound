import Foundation

/// Decides the tunnel's drawable size. The tunnel is all soft glow, so it renders below native resolution (1.5 pixels
/// per point on a Retina panel looks the same and roughly halves the fill cost), capped at `maxPixels`. The first size
/// applies at once; later changes (a full-screen transition, a move between displays, a live resize) wait until the
/// size has stopped changing for `settleSeconds`, and until then the layer stretches the previous drawable.
struct WobbleTunnelDrawableSizer {
    static let maxPixels: CGFloat = 4_000_000
    static let settleSeconds: Double = 0.25

    private(set) var current: CGSize?
    private(set) var pending: CGSize?
    private var pendingSince: Double = 0

    /// The drawable size for a view of `points` on a display with `backingScale`, at `renderScale` of native.
    static func target(points: CGSize, backingScale: CGFloat, renderScale: CGFloat) -> CGSize {
        var width = max(points.width * backingScale * renderScale, 1).rounded()
        var height = max(points.height * backingScale * renderScale, 1).rounded()
        let pixels = width * height
        if pixels > maxPixels {
            let shrink = (maxPixels / pixels).squareRoot()
            width = max((width * shrink).rounded(.down), 1)
            height = max((height * shrink).rounded(.down), 1)
        }
        return CGSize(width: width, height: height)
    }

    /// Returns the size to apply now, or nil when the change has to settle first (see `pending`).
    mutating func propose(_ target: CGSize, at now: Double) -> CGSize? {
        guard let current else {
            self.current = target
            return target
        }
        if target == current {
            pending = nil
            return nil
        }
        if target != pending {
            pending = target
            pendingSince = now
        }
        return nil
    }

    /// Applies the pending size once it has been stable for `settleSeconds`.
    mutating func settle(at now: Double) -> CGSize? {
        guard let pending, now - pendingSince >= Self.settleSeconds else { return nil }
        current = pending
        self.pending = nil
        return pending
    }
}
