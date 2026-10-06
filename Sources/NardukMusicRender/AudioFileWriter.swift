import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Writes rendered audio to a file.
public enum AudioFileWriter {
    public enum WriteError: Error, CustomStringConvertible {
        case unsupported(String)
        case encoder(String)

        public var description: String {
            switch self {
            case .unsupported(let message): message
            case .encoder(let message): "encoder: \(message)"
            }
        }
    }

    /// A 16-bit PCM stereo WAV (RIFF), with TPDF-free plain rounding so the bytes are deterministic.
    public static func wavData(_ audio: RenderedAudio) -> Data {
        let channels = 2
        let bitsPerSample = 16
        let frames = audio.frameCount
        let dataBytes = frames * channels * bitsPerSample / 8
        var data = Data(capacity: 44 + dataBytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(channels))
        append(UInt32(audio.sampleRate))
        append(UInt32(Int(audio.sampleRate) * channels * bitsPerSample / 8))
        append(UInt16(channels * bitsPerSample / 8))
        append(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        var samples = [Int16](repeating: 0, count: frames * channels)
        for i in 0..<frames {
            samples[2 * i] = pcm16(audio.left[i])
            samples[2 * i + 1] = pcm16(audio.right[i])
        }
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { append(sample) }
        }
        return data
    }

    public static func writeWAV(_ audio: RenderedAudio, to url: URL) throws {
        try wavData(audio).write(to: url, options: .atomic)
    }

    /// Writes AAC in an `.m4a` (Apple platforms only).
    public static func writeM4A(_ audio: RenderedAudio, to url: URL, bitRate: Int = 192_000) throws {
        #if canImport(AVFoundation)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitRate,
            ]
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk = 4_096
            guard
                let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2),
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
                let channels = buffer.floatChannelData
            else { throw WriteError.encoder("no PCM buffer") }
            var start = 0
            while start < audio.frameCount {
                let count = min(chunk, audio.frameCount - start)
                for i in 0..<count {
                    channels[0][i] = audio.left[start + i]
                    channels[1][i] = audio.right[start + i]
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                start += count
            }
        #else
            throw WriteError.unsupported("AAC needs AVFoundation; write a WAV on this platform")
        #endif
    }

    private static func pcm16(_ sample: Float) -> Int16 {
        let clamped = min(max(sample.isFinite ? sample : 0, -1), 1)
        return Int16((clamped * 32_767).rounded())
    }
}
