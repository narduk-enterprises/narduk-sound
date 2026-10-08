#if canImport(AVFoundation)
    import AVFoundation
    import Foundation
    import NardukSoundAnalysis

    extension SoundTimelineRecorder {
        public enum FileError: Error, Equatable {
            case unreadable
            case empty
        }

        /// Records a whole audio file faster than real time: the file is downmixed to mono (the mean of its channels, as
        /// `SampleRing` does for a live tap), analyzed by a `SoundAnalyzer` every 1/60 s of audio (the hop a live
        /// display poll has) and recorded. Frame `k` is stamped `(k + 1) / 60` seconds, as `OfflineRenderer` stamps
        /// its ticks; the last partial hop is dropped. The same file gives the same timeline, byte for byte.
        ///
        /// - Parameters:
        ///   - url: any file `AVAudioFile` reads.
        ///   - trackID: defaults to the file's name without its extension (never the path, so two machines agree).
        public static func record(
            fileAt url: URL, trackID: String? = nil, gridRate: Double = SoundTimeline.defaultGridRate
        ) throws -> SoundTimeline {
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: url) } catch { throw FileError.unreadable }
            let format = file.processingFormat
            let sampleRate = format.sampleRate
            let channels = Int(format.channelCount)
            guard file.length > 0, channels > 0, sampleRate > 0 else { throw FileError.empty }
            let hop = Int((sampleRate / 60).rounded())
            let recorder = SoundTimelineRecorder(
                trackID: trackID ?? url.deletingPathExtension().lastPathComponent, gridRate: gridRate,
                analysisSampleRate: sampleRate, analysisRate: sampleRate / Double(hop))
            let analyzer = SoundAnalyzer(sampleRate: sampleRate)
            let chunk = AVAudioFrameCount(hop * 120)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw FileError.unreadable
            }
            var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
            var pending: [Float] = []
            var hops = 0
            while file.framePosition < file.length {
                do { try file.read(into: buffer, frameCount: chunk) } catch { throw FileError.unreadable }
                let frames = Int(buffer.frameLength)
                if frames == 0 { break }
                guard let data = buffer.floatChannelData else { throw FileError.unreadable }
                let gain = 1 / Float(channels)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[c][i] }
                    pending.append(sum * gain)
                }
                var cursor = 0
                while pending.count - cursor >= hop {
                    // Slide the 2048-sample window by one hop.
                    window.withUnsafeMutableBufferPointer { w in
                        let keep = w.count - hop
                        for k in 0..<keep { w[k] = w[k + hop] }
                        for k in 0..<hop { w[keep + k] = pending[cursor + k] }
                    }
                    cursor += hop
                    hops += 1
                    let time = Double(hops * hop) / sampleRate
                    recorder.record(window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) })
                }
                pending.removeFirst(cursor)
            }
            return recorder.finish()
        }
    }
#endif
