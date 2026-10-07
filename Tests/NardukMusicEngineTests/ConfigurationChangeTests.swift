import AVFoundation
import Testing

@testable import NardukMusicEngine

/// An output change (a new route, a different sample rate) or a media-services reset rebuilds only the
/// `AVAudioEngine` graph. These tests drive `handleConfigurationChange()` and `handleMediaServicesReset()` directly
/// (the system notifications cannot be raised on demand) on an offline-rendered engine, so no output device is used
/// and nothing is audible.
@MainActor @Suite struct ConfigurationChangeTests {
    private static func offlineEngine(sampleRate: Double = 48_000) throws -> DropEngine {
        let engine = DropEngine()
        engine.offlineFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        engine.mutesHardwareOutput = true
        return engine
    }

    /// Renders `seconds` in half-second slices, returning the step after each.
    private static func steps(_ engine: DropEngine, seconds: Int) throws -> [Int] {
        try (0..<seconds * 2).map { _ in
            _ = try engine.renderOffline(frames: 24_000)
            return engine.currentStep
        }
    }

    @Test func aConfigurationChangeKeepsTheSynthAndTheStep() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        let before = try Self.steps(engine, seconds: 4)
        let synth = try #require(engine.synthIdentity)
        let stepBefore = try #require(before.last)
        #expect(stepBefore > 0, "the demo never advanced")

        engine.handleConfigurationChange()

        #expect(engine.isRunning && !engine.isPaused)
        #expect(engine.synthIdentity == synth, "the synth was rebuilt")
        #expect(engine.currentStep == stepBefore, "the step moved during the rebuild")
        let after = try Self.steps(engine, seconds: 4)
        #expect(after.first.map { $0 >= stepBefore } == true)
        #expect(zip(after, after.dropFirst()).allSatisfy { $0 <= $1 }, "the step went backwards: \(after)")
        #expect(try #require(after.last) > stepBefore, "the song did not play on")
    }

    @Test func aSampleRateChangeKeepsTheSongAndStillMakesSound() throws {
        let engine = try Self.offlineEngine(sampleRate: 48_000)
        try engine.playDemo()
        defer { engine.stop() }
        _ = try Self.steps(engine, seconds: 2)
        let synth = try #require(engine.synthIdentity)
        let stepBefore = engine.currentStep

        // The output device now runs at 44.1 kHz; the synth stays at 48 kHz and the mixers convert.
        engine.offlineFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        engine.handleConfigurationChange()

        #expect(engine.synthIdentity == synth)
        #expect(engine.synthSampleRate == 48_000)
        let out = try engine.renderOffline(frames: 44_100)
        #expect(out.format.sampleRate == 44_100)
        #expect(SilentOutputTests.peak(of: out) == 0, "muted hardware path was not silent after the rebuild")
        #expect(engine.currentStep >= stepBefore)
        engine.mutesHardwareOutput = false
        let loud = try engine.renderOffline(frames: 44_100)
        #expect(SilentOutputTests.peak(of: loud) > 0.01, "no sound after the sample-rate change")
    }

    @Test func manyConfigurationChangesNeverRestartTheSong() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        var last = 0
        for round in 0..<6 {
            _ = try engine.renderOffline(frames: 24_000)
            engine.handleConfigurationChange()
            #expect(engine.currentStep >= last, "round \(round): the step fell back to \(engine.currentStep)")
            last = engine.currentStep
        }
        #expect(last > 0)
    }

    @Test func aPausedSongStaysHeldThroughAConfigurationChange() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        _ = try Self.steps(engine, seconds: 2)
        engine.pause()
        let step = engine.currentStep
        let synth = engine.synthIdentity

        engine.handleConfigurationChange()

        #expect(engine.isRunning && engine.isPaused, "the rebuild resumed a paused song")
        #expect(engine.currentStep == step)
        #expect(engine.synthIdentity == synth)
    }

    @Test func aStoppedEngineIgnoresAConfigurationChange() {
        let engine = DropEngine()
        engine.handleConfigurationChange()
        engine.handleMediaServicesReset()
        #expect(!engine.isRunning && engine.synthIdentity == nil)
    }

    @Test func aMediaServicesResetKeepsTheSynthAndTheStepOnANewEngine() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        _ = try Self.steps(engine, seconds: 3)
        let synth = try #require(engine.synthIdentity)
        let stepBefore = engine.currentStep
        #expect(stepBefore > 0)

        engine.handleMediaServicesReset()

        #expect(engine.isRunning && !engine.isPaused)
        #expect(engine.synthIdentity == synth)
        #expect(engine.currentStep == stepBefore)
        let after = try Self.steps(engine, seconds: 2)
        #expect(zip(after, after.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(try #require(after.last) > stepBefore)
    }

    @Test func unpluggingTheOutputPausesAndResumeContinuesFromTheSameStep() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        _ = try Self.steps(engine, seconds: 2)
        let step = engine.currentStep
        let synth = engine.synthIdentity

        engine.handleRouteChange(reason: .oldDeviceUnavailable)
        #expect(engine.isRunning && engine.isPaused)
        #expect(engine.currentStep == step)

        try engine.resume()
        #expect(!engine.isPaused)
        #expect(engine.synthIdentity == synth)
        let after = try Self.steps(engine, seconds: 1)
        #expect(after.allSatisfy { $0 >= step })
    }

    @Test func aRouteConfigurationChangeKeepsPlaying() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        for reason in [RouteChangeReason.routeConfigurationChange, .newDeviceAvailable, .categoryChange] {
            engine.handleRouteChange(reason: reason)
            #expect(engine.isRunning && !engine.isPaused, "\(reason) paused the song")
        }
    }

    @Test func anInterruptionPausesWithoutLosingThePlaceAndResumesWithTheHint() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        _ = try Self.steps(engine, seconds: 2)
        let step = engine.currentStep
        let synth = engine.synthIdentity

        engine.handleInterruption(began: true, shouldResume: false)
        #expect(engine.isRunning && engine.isPaused)
        engine.handleInterruption(began: false, shouldResume: true)
        #expect(!engine.isPaused)
        #expect(engine.currentStep == step)
        #expect(engine.synthIdentity == synth)
    }

    @Test func anInterruptionWithoutTheHintLeavesTheSongPaused() throws {
        let engine = try Self.offlineEngine()
        try engine.playDemo()
        defer { engine.stop() }
        engine.handleInterruption(began: true, shouldResume: false)
        engine.handleInterruption(began: false, shouldResume: false)
        #expect(engine.isPaused, "resumed without the system's shouldResume")
    }
}
