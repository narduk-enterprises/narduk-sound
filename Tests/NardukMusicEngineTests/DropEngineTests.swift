import NardukMusicCore
import NardukMusicDSP
import NardukMusicEngine
import Testing

/// The engine's controls, without starting it: these tests never open an audio device or play to the speakers.
@MainActor @Suite struct DropEngineTests {
    @Test func aNewEngineIsStoppedWithUnityGains() {
        let engine = DropEngine()
        #expect(!engine.isRunning)
        #expect(!engine.isRecording)
        #expect(engine.currentStep == 0)
        for channel in MixerChannel.allCases { #expect(engine.gain(for: channel) == 1) }
    }

    @Test func gainsClampAndMutesToggle() {
        let engine = DropEngine()
        engine.setGain(4, for: .bass)
        engine.setGain(-.infinity, for: .drums)
        #expect(engine.gain(for: .bass) == 1.5)
        #expect(engine.gain(for: .drums) == 0)
        engine.setMuted(true, for: .fx)
        #expect(engine.mutes == [.fx])
        engine.setMuted(false, for: .fx)
        #expect(engine.mutes.isEmpty)
    }

    @Test func recordingNeedsARunningEngine() {
        let engine = DropEngine()
        #expect(throws: DropEngineError.self) {
            try engine.startRecording(to: .temporaryDirectory.appending(path: "never.m4a"))
        }
    }

    @Test func aStoppedEngineHasNoSoundSource() {
        #expect(DropEngine().makeSoundSource() == nil)
    }

    @Test func stoppingAStoppedEngineIsHarmless() {
        let engine = DropEngine()
        engine.stop()
        #expect(!engine.isRunning)
    }

    @Test func theDemoProviderEmitsEachStepOnce() {
        let demo = DropEngineDemo()
        let first = demo.notes(through: 15)
        #expect(!first.isEmpty && first.allSatisfy { (0...15).contains($0.step) })
        #expect(demo.notes(through: 15).isEmpty)
        #expect(demo.notes(through: 31).allSatisfy { (16...31).contains($0.step) })
    }
}
