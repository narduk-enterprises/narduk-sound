import Foundation
import NardukMusicCore

/// A small Freeverb-style stereo room (4 damped combs + 2 allpasses per side) for the snare.
/// Owns raw buffers: call `deallocate()` exactly once when done.
public struct RoomReverb: @unchecked Sendable {
    private struct Line {
        var buffer: UnsafeMutablePointer<Float>
        var length: Int
        var position = 0
        var store: Float = 0
    }

    private static let combTunings = [1116, 1277, 1422, 1557]
    private static let allpassTunings = [556, 341]
    private static let stereoSpread = 23

    private let combs: UnsafeMutablePointer<Line>  // 4 left, then 4 right
    private let allpasses: UnsafeMutablePointer<Line>  // 2 left, then 2 right
    public var feedback: Float = 0.76
    public var damping: Float = 0.32

    public init(sampleRate: Double, size: Double = 0.55) {
        let scale = sampleRate / 44_100 * size
        combs = .allocate(capacity: 8)
        allpasses = .allocate(capacity: 4)
        for side in 0..<2 {
            for (i, tuning) in RoomReverb.combTunings.enumerated() {
                let length = max(Int(Double(tuning + side * RoomReverb.stereoSpread) * scale), 8)
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
                buffer.initialize(repeating: 0, count: length)
                (combs + side * 4 + i).initialize(to: Line(buffer: buffer, length: length))
            }
            for (i, tuning) in RoomReverb.allpassTunings.enumerated() {
                let length = max(Int(Double(tuning + side * RoomReverb.stereoSpread) * sampleRate / 44_100), 8)
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
                buffer.initialize(repeating: 0, count: length)
                (allpasses + side * 2 + i).initialize(to: Line(buffer: buffer, length: length))
            }
        }
    }

    public func deallocate() {
        for i in 0..<8 { combs[i].buffer.deallocate() }
        for i in 0..<4 { allpasses[i].buffer.deallocate() }
        combs.deallocate()
        allpasses.deallocate()
    }

    @inline(__always) public mutating func process(_ input: Float) -> (Float, Float) {
        let x = input * 0.06
        var outLeft: Float = 0
        var outRight: Float = 0
        for i in 0..<8 {
            let line = combs + i
            let y = line.pointee.buffer[line.pointee.position]
            line.pointee.store = y * (1 - damping) + line.pointee.store * damping + DSP.antiDenormal
            line.pointee.buffer[line.pointee.position] = x + line.pointee.store * feedback
            line.pointee.position += 1
            if line.pointee.position == line.pointee.length { line.pointee.position = 0 }
            if i < 4 { outLeft += y } else { outRight += y }
        }
        for i in 0..<4 {
            let line = allpasses + i
            let buffered = line.pointee.buffer[line.pointee.position]
            let input = i < 2 ? outLeft : outRight
            let y = buffered - input
            line.pointee.buffer[line.pointee.position] = input + buffered * 0.5 + DSP.antiDenormal
            line.pointee.position += 1
            if line.pointee.position == line.pointee.length { line.pointee.position = 0 }
            if i < 2 { outLeft = y } else { outRight = y }
        }
        return (outLeft, outRight)
    }
}
