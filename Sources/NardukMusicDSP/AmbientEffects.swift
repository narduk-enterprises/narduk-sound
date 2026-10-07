import Foundation
import NardukMusicCore

// The ambient family's space: a long-tailed stereo hall and a tempo-synced stereo delay. Both own raw buffers and are
// real-time safe like `RoomReverb`: `deallocate()` exactly once, no allocation while rendering.

/// A long stereo reverb (8 damped combs and 4 allpasses per side) whose tail length is a time: `decaySeconds` is the
/// time the tail takes to fall 60 dB, the same for every comb whatever its length.
public struct HallReverb: @unchecked Sendable {
    private struct Line {
        var buffer: UnsafeMutablePointer<Float>
        var length: Int
        var position = 0
        var store: Float = 0
        var feedback: Float = 0
    }

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 31
    /// The longest tail `decaySeconds` accepts.
    public static let maxDecaySeconds: Float = 30

    private let combs: UnsafeMutablePointer<Line>  // 8 left, then 8 right
    private let allpasses: UnsafeMutablePointer<Line>  // 4 left, then 4 right
    private let sampleRate: Float
    private var inputGain: Float = 0.03
    /// 0 (bright) ... 1 (dark): how fast the high end dies inside the tail.
    public var damping: Float = 0.3
    public private(set) var decaySeconds: Float = 6

    /// `size` stretches the delay lines: 1 is a medium room, 2.2 a large hall.
    public init(sampleRate: Double, decaySeconds: Float = 6, size: Double = 2.2) {
        self.sampleRate = Float(sampleRate)
        let scale = sampleRate / 44_100 * size
        combs = .allocate(capacity: 16)
        allpasses = .allocate(capacity: 8)
        for side in 0..<2 {
            for (i, tuning) in HallReverb.combTunings.enumerated() {
                let length = max(Int(Double(tuning + side * HallReverb.stereoSpread) * scale), 8)
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
                buffer.initialize(repeating: 0, count: length)
                (combs + side * 8 + i).initialize(to: Line(buffer: buffer, length: length))
            }
            for (i, tuning) in HallReverb.allpassTunings.enumerated() {
                let length = max(Int(Double(tuning + side * HallReverb.stereoSpread) * sampleRate / 44_100), 8)
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
                buffer.initialize(repeating: 0, count: length)
                (allpasses + side * 4 + i).initialize(to: Line(buffer: buffer, length: length))
            }
        }
        setDecay(seconds: decaySeconds)
    }

    public func deallocate() {
        for i in 0..<16 { combs[i].buffer.deallocate() }
        for i in 0..<8 { allpasses[i].buffer.deallocate() }
        combs.deallocate()
        allpasses.deallocate()
    }

    /// Sets the 60 dB tail time. Each comb gets the feedback that makes its own length fall 60 dB in that time.
    public mutating func setDecay(seconds: Float) {
        let clamped = min(max(seconds.isFinite ? seconds : 1, 0.1), HallReverb.maxDecaySeconds)
        decaySeconds = clamped
        for i in 0..<16 {
            let length = Float(combs[i].length)
            combs[i].feedback = powf(10, -3 * length / (clamped * sampleRate))
        }
    }

    /// `setDecay(seconds:)` unless the tail time is already that (the render thread calls this every buffer).
    public mutating func setDecayIfChanged(_ seconds: Float) {
        let clamped = min(max(seconds.isFinite ? seconds : 1, 0.1), HallReverb.maxDecaySeconds)
        if abs(clamped - decaySeconds) > 1e-4 { setDecay(seconds: clamped) }
    }

    /// One stereo sample in, one stereo wet sample out (no dry signal).
    @inline(__always) public mutating func process(_ left: Float, _ right: Float) -> (Float, Float) {
        let x = (left + right) * 0.5 * inputGain
        var outLeft: Float = 0
        var outRight: Float = 0
        for i in 0..<16 {
            let line = combs + i
            let y = line.pointee.buffer[line.pointee.position]
            line.pointee.store = y * (1 - damping) + line.pointee.store * damping + DSP.antiDenormal
            line.pointee.buffer[line.pointee.position] = x + line.pointee.store * line.pointee.feedback
            line.pointee.position += 1
            if line.pointee.position == line.pointee.length { line.pointee.position = 0 }
            if i < 8 { outLeft += y } else { outRight += y }
        }
        for i in 0..<8 {
            let line = allpasses + i
            let buffered = line.pointee.buffer[line.pointee.position]
            let input = i < 4 ? outLeft : outRight
            let y = buffered - input
            line.pointee.buffer[line.pointee.position] = input + buffered * 0.5 + DSP.antiDenormal
            line.pointee.position += 1
            if line.pointee.position == line.pointee.length { line.pointee.position = 0 }
            if i < 4 { outLeft = y } else { outRight = y }
        }
        return (outLeft, outRight)
    }
}

/// A stereo delay with feedback: tempo-synced (`setTime(steps:bpm:)`) or free (`setTime(seconds:)`), optionally
/// ping-pong, with a lowpass in the feedback path so each repeat is darker. Changing the time glides (like tape) instead
/// of jumping, so a tempo change never clicks.
public struct StereoDelay: @unchecked Sendable {
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var write = 0
    private var current: Float
    private var target: Float
    private let slew: Float
    private var dampLeft = OnePole()
    private var dampRight = OnePole()
    /// Share of each echo fed back, 0 ... 0.95.
    public var feedback: Float = 0.5 {
        didSet { feedback = min(max(feedback.isFinite ? feedback : 0, 0), 0.95) }
    }
    /// Each repeat crosses to the other side, so echoes bounce left and right.
    public var pingPong = true

    /// The longest delay in seconds.
    public static let maxSeconds = 4.0

    public init(sampleRate: Double, seconds: Double = 0.375, dampingHz: Float = 3_500) {
        capacity = Int(StereoDelay.maxSeconds * sampleRate) + 2
        left = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right = .allocate(capacity: capacity)
        right.initialize(repeating: 0, count: capacity)
        let samples = Float(min(max(seconds, 0.001), StereoDelay.maxSeconds) * sampleRate)
        current = samples
        target = samples
        slew = 1 - expf(-1 / Float(0.25 * sampleRate))
        dampLeft.setCutoff(dampingHz, sampleRate: Float(sampleRate))
        dampRight.setCutoff(dampingHz, sampleRate: Float(sampleRate))
    }

    public func deallocate() {
        left.deallocate()
        right.deallocate()
    }

    /// A free time.
    public mutating func setTime(seconds: Double, sampleRate: Double) {
        target = Float(min(max(seconds, 0.001), StereoDelay.maxSeconds) * sampleRate)
    }

    /// A time of `steps` sixteenth notes at `bpm` (6 steps is a dotted eighth, 4 a quarter).
    public mutating func setTime(steps: Double, bpm: Double, sampleRate: Double) {
        setTime(seconds: steps * 60 / max(bpm, 1) / 4, sampleRate: sampleRate)
    }

    /// The delay now, in samples (it glides toward the time last set).
    public var samples: Float { current }

    /// One stereo sample in, one stereo wet sample out (the echoes only).
    @inline(__always) public mutating func process(_ inLeft: Float, _ inRight: Float) -> (Float, Float) {
        current += (target - current) * slew
        var read = Float(write) - current
        if read < 0 { read += Float(capacity) }
        let base = Int(read)
        let frac = read - Float(base)
        let next = base + 1 == capacity ? 0 : base + 1
        let echoLeft = left[base] + (left[next] - left[base]) * frac
        let echoRight = right[base] + (right[next] - right[base]) * frac
        let fedLeft = dampLeft.lowpass(pingPong ? echoRight : echoLeft) * feedback
        let fedRight = dampRight.lowpass(pingPong ? echoLeft : echoRight) * feedback
        left[write] = inLeft + fedLeft
        right[write] = inRight + fedRight
        write += 1
        if write == capacity { write = 0 }
        return (echoLeft, echoRight)
    }
}
