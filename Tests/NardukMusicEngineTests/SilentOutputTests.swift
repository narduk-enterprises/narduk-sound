import AVFoundation
import CoreAudio
import NardukSoundAnalysis
import Testing

@testable import NardukMusicEngine

/// `mutesHardwareOutput` (narduk-libs#1625) silences the speaker path and nothing the app can see: the recording and
/// the `SoundFrameSource` keep the full signal. The engine-running test starts the synth muted, so it makes no sound.
@MainActor @Suite struct SilentOutputTests {
    /// False on a host with no default audio output device (a CI runner): the running test skips there. Asks Core Audio
    /// directly: an `AVAudioEngine` without a device crashes when asked for its output format.
    nonisolated static let hasOutputDevice: Bool = {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }()

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

    @Test(.enabled(if: hasOutputDevice, "no audio output device on this host"))
    func recordingAndMeteringSeeTheFullSignalWhileTheSpeakerIsMuted() async throws {
        let engine = DropEngine()
        engine.mutesHardwareOutput = true
        try engine.playDemo()
        defer { engine.stop() }
        #expect(engine.hardwareVolume == 0, "the speaker path was not muted before sound played")
        let source = try #require(engine.makeSoundSource())
        let url = URL.temporaryDirectory.appending(path: "silent-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try engine.startRecording(to: url)
        var loudest: Float = -.infinity
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(100))
            loudest = max(loudest, source.poll(time: Double(started.duration(to: .now).components.seconds)).rmsDB)
        }
        #expect(engine.hardwareVolume == 0)
        let recorded = try #require(await engine.stopRecording())
        #expect(try Self.rms(of: recorded) > 0.005, "the recording is silent while muted")
        #expect(loudest > -40, "the meter saw only silence (\(loudest) dB) while muted")
    }
}
