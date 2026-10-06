import AVFoundation
import Foundation
import os

/// Writes master-bus buffers from a mixer tap to an AAC `.m4a`. The tap runs on an
/// AVFoundation worker thread, never the render thread, so file I/O is safe there.
final class DropRecorder: @unchecked Sendable {
    let url: URL
    private let file: OSAllocatedUnfairLock<AVAudioFile?>
    private let failed = OSAllocatedUnfairLock(initialState: false)

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 256_000,
        ]
        let audioFile = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        file = OSAllocatedUnfairLock(uncheckedState: audioFile)
    }

    /// The tap block, built outside any actor so it carries no isolation.
    nonisolated func makeTapBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in write(buffer) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        file.withLockUnchecked { file in
            guard let file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                failed.withLock { $0 = true }
            }
        }
    }

    /// Closes the file (finalizing the AAC stream) and returns its URL, or nil if writing failed.
    func finish() -> URL? {
        file.withLockUnchecked { $0 = nil }
        let didFail = failed.withLock { $0 }
        return didFail ? nil : url
    }
}
