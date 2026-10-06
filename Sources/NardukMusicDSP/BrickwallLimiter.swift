import Foundation
import NardukMusicCore

/// A stereo look-ahead brickwall limiter with a guaranteed sample-peak ceiling.
///
/// For each input sample it computes the gain that would put that sample at the
/// ceiling, takes the minimum of that over the look-ahead window (a hold), lets the
/// hold recover with a one-pole release, then smooths it with a box filter of the
/// same length and applies it to the signal delayed by `latency` samples. Every gain
/// the box averages over is at most the gain the delayed sample needs, so the output
/// never exceeds the ceiling; a final clamp guards float rounding only.
///
/// Owns raw buffers: call `deallocate()` exactly once when done (the synth core does).
public struct BrickwallLimiter: @unchecked Sendable {
    public let lookahead: Int
    public let ceiling: Float
    private let target: Float
    private let delayLeft: UnsafeMutablePointer<Float>
    private let delayRight: UnsafeMutablePointer<Float>
    private let required: UnsafeMutablePointer<Float>
    private let box: UnsafeMutablePointer<Float>
    private var position = 0
    /// Running minimum of `required` over the window, and the slot holding it (amortized O(1)).
    private var hold: Float = 1
    private var holdSlot = 0
    private var boxSum: Double
    private var released: Float = 1
    private let releaseMultiplier: Float
    /// The lowest gain applied since the last `takeMinimumGain()`, for metering.
    public private(set) var minimumGain: Float = 1

    public init(
        sampleRate: Double, lookaheadSeconds: Double = 0.002, releaseSeconds: Double = 0.08, ceilingDB: Float = -1
    ) {
        lookahead = min(max(Int((sampleRate * lookaheadSeconds).rounded()), 4), 1024)
        ceiling = powf(10, ceilingDB / 20)
        target = ceiling * 0.9995
        releaseMultiplier = DSP.decay(seconds: Float(releaseSeconds), sampleRate: Float(sampleRate))
        delayLeft = .allocate(capacity: lookahead)
        delayRight = .allocate(capacity: lookahead)
        required = .allocate(capacity: lookahead)
        box = .allocate(capacity: lookahead)
        delayLeft.initialize(repeating: 0, count: lookahead)
        delayRight.initialize(repeating: 0, count: lookahead)
        required.initialize(repeating: 1, count: lookahead)
        box.initialize(repeating: 1, count: lookahead)
        boxSum = Double(lookahead)
    }

    public func deallocate() {
        delayLeft.deallocate()
        delayRight.deallocate()
        required.deallocate()
        box.deallocate()
    }

    /// Samples of delay the limiter adds.
    public var latency: Int { lookahead - 1 }

    @inline(__always) public mutating func process(_ left: Float, _ right: Float) -> (Float, Float) {
        let peak = max(abs(left), abs(right))
        let need: Float = peak > target ? target / peak : 1
        let slot = position
        required[slot] = need
        if need <= hold {
            hold = need
            holdSlot = slot
        } else if holdSlot == slot {
            // The window minimum just expired: rescan (at most once per window while limiting).
            hold = 1
            for i in 0..<lookahead where required[i] <= hold {
                hold = required[i]
                holdSlot = i
            }
        }

        if hold < released {
            released = hold
        } else {
            released = hold + (released - hold) * releaseMultiplier
        }

        boxSum += Double(released - box[slot])
        box[slot] = released
        let g = min(Float(boxSum / Double(lookahead)), 1)

        delayLeft[slot] = left
        delayRight[slot] = right
        let read = slot + 1 == lookahead ? 0 : slot + 1
        position = read

        if g < minimumGain { minimumGain = g }
        let outLeft = min(max(delayLeft[read] * g, -ceiling), ceiling)
        let outRight = min(max(delayRight[read] * g, -ceiling), ceiling)
        return (outLeft, outRight)
    }

    public mutating func takeMinimumGain() -> Float {
        let value = minimumGain
        minimumGain = 1
        return value
    }
}
