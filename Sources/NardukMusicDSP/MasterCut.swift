import Foundation
import NardukMusicCore

/// The master "cut" (narduk-libs#1641): beat repeat, trance gate, reverse slice and re-sliced chops over the master
/// history, locked to the sample the event fires on. A plain value: the history it reads belongs to the core.
struct MasterCut: Sendable {
    /// Samples the edges of a slice (and the way in and out) are smoothed over, about a millisecond.
    static let ramp = 48
    /// How many slices a `chop` re-sequences.
    static let chopSlices = 8

    private(set) var remaining = 0
    private var length = 0
    private var age = 0
    private var slice = 1
    private var start = 0
    private var mode = CutMode.stutter
    private var amount: Float = 0.5
    private var rng: UInt32 = 1
    private var chopIndex = 0
    private var chopSilent = false

    var isActive: Bool { remaining > 0 }

    /// Starts a cut on the next sample `process` sees. `historyWrite` is the index that sample will be written to, so
    /// the slice just before it is `historyWrite - slice` ..< `historyWrite`.
    mutating func begin(
        mode: CutMode, slice sliceSamples: Int, length lengthSamples: Int, amount a: Float, seed: UInt32,
        historyWrite: Int
    ) {
        self.mode = mode
        slice = max(sliceSamples, 2 * MasterCut.ramp)
        length = max(lengthSamples, slice)
        remaining = length
        age = 0
        amount = min(max(a, 0), 1)
        rng = seed == 0 ? 0x9E37_79B9 : seed &* 2_654_435_761 | 1
        switch mode {
        case .chop:
            start = historyWrite - slice * MasterCut.chopSlices
            chooseChop()
        default:
            start = historyWrite - slice
        }
    }

    private mutating func nextRandom() -> UInt32 {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return rng
    }

    private mutating func chooseChop() {
        chopIndex = Int(nextRandom() % UInt32(MasterCut.chopSlices))
        chopSilent = Float(nextRandom() % 1_000) / 1_000 < amount * 0.6
    }

    /// Replaces the dry sample with the cut. `history` is the core's ring (already holding the dry sample at the
    /// current write index) and `mask` its size minus one.
    @inline(__always) mutating func process(
        _ left: Float, _ right: Float, historyLeft: UnsafeMutablePointer<Float>,
        historyRight: UnsafeMutablePointer<Float>, mask: Int
    ) -> (Float, Float) {
        guard remaining > 0 else { return (left, right) }
        let ramp = Float(MasterCut.ramp)
        let position = age % slice
        let cycle = age / slice
        if position == 0 && cycle > 0 && mode == .chop { chooseChop() }
        // Dry at the cut's first sample's edge, wet within a millisecond, and dry again over its last millisecond.
        let blend = min(min(Float(age + 1) / ramp, Float(remaining) / ramp), 1)
        let edge = min(Float(min(position + 1, slice - position)) / ramp, 1)
        var wetLeft: Float
        var wetRight: Float
        switch mode {
        case .stutter:
            let progress = min(Float(cycle) / 7, 1)
            let rate = 1 + amount * progress  // up to an octave up
            let read = rate == 1 ? position : Int(Float(position) * rate) % slice
            let index = (start + read) & mask
            let level = 1 - 0.6 * amount * progress
            wetLeft = historyLeft[index] * level * edge
            wetRight = historyRight[index] * level * edge
        case .reverse:
            let index = (start + slice - 1 - position) & mask
            wetLeft = historyLeft[index] * edge
            wetRight = historyRight[index] * edge
        case .gate:
            let open = Float(slice) * (0.5 - 0.4 * amount)
            let into = Float(position)
            let gain = min(into / ramp, 1) * min(max((open - into) / ramp, 0), 1)
            wetLeft = left * gain
            wetRight = right * gain
        case .chop:
            if chopSilent {
                wetLeft = 0
                wetRight = 0
            } else {
                let index = (start + chopIndex * slice + position) & mask
                wetLeft = historyLeft[index] * edge
                wetRight = historyRight[index] * edge
            }
        }
        age += 1
        remaining -= 1
        if blend >= 1 { return (wetLeft, wetRight) }
        return (left + (wetLeft - left) * blend, right + (wetRight - right) * blend)
    }
}
