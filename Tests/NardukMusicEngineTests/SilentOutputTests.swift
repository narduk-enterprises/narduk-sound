import AVFoundation
import NardukSoundAnalysis
import Testing

@testable import NardukMusicEngine

/// `mutesHardwareOutput` (narduk-libs#1625) silences the speaker path and nothing the app can see: the recording and
/// the `SoundFrameSource` keep the full signal. The running test renders the graph offline (manual rendering), so it
/// needs no output device, makes no sound and does not depend on a real-time clock: it is the same on a CI runner.
@MainActor @Suite struct SilentOutputTests {
    @Test func theSpeakerPathIsOnByDefaultAndMutesAtOnce() {
        let engine = DropEngine()
        #expect(!engine.mutesHardwareOutput)
        #expect(engine.hardwareVolume == 1)
        engine.mutesHardwareOutput = true
        #expect(engine.hardwareVolume == 0)
        engine.mutesHardwareOutput = false
        #expect(engine.hardwareVolume == 1)
    }

    @Test func mutingTheHardwareLeavesTheSynthsOwnVolumeAlone() {
        let engine = DropEngine()
        let before = engine.masterVolume
        engine.mutesHardwareOutput = true
        #expect(engine.masterVolume == before)
    }

    /// RMS of every sample in the file at `url`.
    static func rms(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        try file.read(into: buffer)
        var sum: Float = 0
        var count = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = try #require(buffer.floatChannelData?[channel])
            for index in 0..<Int(buffer.frameLength) {
                sum += samples[index] * samples[index]
                count += 1
            }
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : 0
    }

    @Test func recordingAndMeteringSeeTheFullSignalWhileTheSpeakerIsMuted() async throws {
        let engine = DropEngine()
        engine.offlineFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        engine.mutesHardwareOutput = true
        try engine.playDemo()
        defer { engine.stop() }
        #expect(engine.hardwareVolume == 0, "the speaker path was not muted before sound played")
        let source = try #require(engine.makeSoundSource())
        let url = URL.temporaryDirectory.appending(path: "silent-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try engine.startRecording(to: url)

        // Two seconds of the demo, in slices, polling the meter as a visualizer would.
        var loudest: Float = -.infinity
        var speaker: Float = 0
        for second in 0..<2 {
            let out = try engine.renderOffline(frames: 48_000)
            speaker = max(speaker, Self.peak(of: out))
            loudest = max(loudest, source.poll(time: Double(second) + 1).rmsDB)
        }
        #expect(speaker == 0, "the speaker path carried sound (peak \(speaker)) while muted")
        let recorded = try #require(await engine.stopRecording())
        #expect(try Self.rms(of: recorded) > 0.005, "the recording is silent while muted")
        #expect(loudest > -40, "the meter saw only silence (\(loudest) dB) while muted")
    }

    @Test func theSpeakerPathCarriesTheSignalWhenNotMuted() throws {
        let engine = DropEngine()
        engine.offlineFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        try engine.playDemo()
        defer { engine.stop() }
        let out = try engine.renderOffline(frames: 96_000)
        #expect(
            Self.peak(of: out) > 0.01, "the unmuted speaker path was silent: the test cannot tell muted from broken")
    }

    /// Largest absolute sample in `buffer`.
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            guard let samples = buffer.floatChannelData?[channel] else { continue }
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
        }
        return peak
    }
}
