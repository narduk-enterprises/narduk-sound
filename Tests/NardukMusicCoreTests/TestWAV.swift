import Foundation

/// Writes a 16-bit stereo WAV for listening to a test render by hand.
enum WAVWriter {
    static func write16(
        left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Int, to url: URL
    ) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataBytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(2))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 4))
        append(UInt16(4))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        data.reserveCapacity(44 + dataBytes)
        for i in 0..<frames {
            append(Int16(max(min(left[i], 1), -1) * 32_767))
            append(Int16(max(min(right[i], 1), -1) * 32_767))
        }
        try data.write(to: url)
    }
}
