import Foundation
import NardukMusicCore

/// The master filter on the render thread: a high-pass and a low-pass state-variable filter per channel, glided to the
/// target in the log-frequency domain (about 20 ms) so a sweep is smooth and a snap open is quick but click-free. While
/// both are open and settled it does nothing at all (`process` returns its input), so an idle filter is bit-identical to
/// no filter. No allocation: four small structs and a counter.
struct MasterFilterState {
    private var highL = SVF()
    private var highR = SVF()
    private var lowL = SVF()
    private var lowR = SVF()
    private var highHz = MasterFilter.highPassOpen
    private var lowHz = MasterFilter.lowPassOpen
    private var active = false
    private var counter = 0
    /// Samples between coefficient updates (the `tanf` is the expensive part).
    private static let interval = 16

    @inline(__always)
    mutating func process(
        _ left: Float, _ right: Float, target: MasterFilter, sampleRate: Float, glide: Float
    ) -> (Float, Float) {
        if !active {
            if target.isIdle { return (left, right) }
            active = true
            highHz = MasterFilter.highPassOpen
            lowHz = MasterFilter.lowPassOpen
            highL.reset()
            highR.reset()
            lowL.reset()
            lowR.reset()
            counter = 0
        }
        if counter & (Self.interval - 1) == 0 {
            highHz *= powf(max(target.highPassHz, 1) / highHz, glide)
            lowHz *= powf(max(target.lowPassHz, 1) / lowHz, glide)
            highL.set(cutoff: highHz, resonance: target.resonance, sampleRate: sampleRate)
            highR.set(cutoff: highHz, resonance: target.resonance, sampleRate: sampleRate)
            lowL.set(cutoff: lowHz, resonance: target.resonance, sampleRate: sampleRate)
            lowR.set(cutoff: lowHz, resonance: target.resonance, sampleRate: sampleRate)
            if target.isIdle, highHz <= MasterFilter.highPassOpen * 1.01, lowHz >= MasterFilter.lowPassOpen * 0.99 {
                active = false
                return (left, right)
            }
        }
        counter &+= 1
        let l = lowL.process(highL.process(left).high).low
        let r = lowR.process(highR.process(right).high).low
        return (l, r)
    }

    /// The per-update glide fraction for a ~20 ms time constant.
    static func glide(sampleRate: Float) -> Float { 1 - expf(-Float(interval) / (sampleRate * 0.02)) }
}
