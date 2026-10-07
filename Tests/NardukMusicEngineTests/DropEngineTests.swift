import NardukMusicCore
import NardukMusicDSP
import NardukMusicEngine
import NardukSoundAnalysis
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

    @Test func aStoppedEnginePublishesQuietContractFrames() {
        let engine = DropEngine()
        #expect(engine.latestSound == SoundFrame())
        #expect(engine.latestMusic == MusicContext())
        #expect(!engine.latestMusic.isRunning)
    }

    /// The deprecated frame is an adapter: it carries the contract values and turns moved counters into `hits`.
    @available(*, deprecated)
    @Test func theDeprecatedFrameIsBuiltFromTheContractTypes() {
        var music = MusicContext(step: 7, section: .drop, wobblePhase: 0.25, wobbleCutoff: 0.5)
        let previous = music.hitCounts
        music.hitCounts.record(.kick)
        music.hitCounts.record(.kick)
        music.hitCounts.record(.snare)
        let sound = SoundFrame(sequence: 3, time: 1, peakDB: -6, rmsDB: -12)
        let frame = VisualizerFrame(sound: sound, music: music, previousHits: previous)
        #expect(frame.hits == [.kick, .snare])
        #expect(frame.step == 7 && frame.section == .drop)
        #expect(frame.wobblePhase == 0.25 && frame.wobbleCutoff == 0.5)
        #expect(frame.peakDB == -6 && frame.rmsDB == -12)
        #expect(frame.spectrum == sound.spectrum && frame.waveform == sound.waveform)
        #expect(VisualizerFrame(sound: sound, music: music, previousHits: music.hitCounts).hits.isEmpty)
        #expect(DropEngine().latestFrame.hits.isEmpty)
    }
}
