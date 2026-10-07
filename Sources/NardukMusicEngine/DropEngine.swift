import AVFoundation
import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukSoundAnalysis
import Observation

/// The engine's mixer channels.
public enum MixerChannel: String, CaseIterable, Sendable {
    case drums, bass, fx

    public var bus: SynthBus {
        switch self {
        case .drums: .drums
        case .bass: .bass
        case .fx: .fx
        }
    }
}

public enum DropEngineError: LocalizedError {
    case notRunning
    case alreadyRecording
    case noOutputFormat

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Start playback before recording."
        case .alreadyRecording: "A recording is already in progress."
        case .noOutputFormat: "No audio output device is available."
        }
    }
}

/// Plays the conductor's notes through the DSP synth (`DropSynthCore`) on an
/// `AVAudioSourceNode`, and publishes analysis for the visualizers.
///
/// Main actor side: a ~60 Hz timer asks `noteProvider` for notes ~100 ms ahead of the
/// render position, pushes them through a lock-free ring, and publishes `latestSound` and `latestMusic`.
/// Render side: the source node calls `DropSynthCore.render`, which never allocates or locks.
/// Steps restart at 0 on every `start()`.
@MainActor @Observable public final class DropEngine {
    /// BPM changes apply at the next bar.
    public var settings: SongSettings {
        didSet { core?.setTempo(settings.bpm) }
    }

    public private(set) var isRunning = false
    /// The step currently audible (output-latency compensated).
    public private(set) var currentStep = 0
    /// What the sound is doing, updated ~60 Hz on the main actor (`sequence` advances once per publish). Not
    /// observed: visualizers poll it on their own frame clock, so publishing a frame never invalidates a SwiftUI body
    /// or Canvas (Wirewatcher #65: that was 50+ invalidations a second).
    @ObservationIgnored public private(set) var latestSound = SoundFrame()
    /// What the music knows about itself, published with `latestSound`. Hits are monotonic counters: keep the
    /// `hitCounts` you last saw and take `delta(since:)`, so a consumer that skips frames loses no hit.
    @ObservationIgnored public private(set) var latestMusic = MusicContext()
    /// Conductor state the controller owns (energy, thresholds, a queued drop); echoed into `latestMusic`.
    @ObservationIgnored public var conductor = ConductorSnapshot()
    /// Set by the controller and echoed into frames.
    public var section: SongSection = .intro
    @ObservationIgnored private var previousHits = HitCounters()
    /// Each `start()` builds a new synth whose counters begin at 0; the published counters add them to this base, so
    /// they stay monotonic across restarts and a consumer's wrapping `delta` never sees a jump back.
    @ObservationIgnored private var hitBase = HitCounters()

    /// The pre-0.4.0 frame, built from `latestSound` and `latestMusic`; its `hits` are the instruments that fired since
    /// the previous publish.
    @available(*, deprecated, message: "Read latestSound (SoundFrame) and latestMusic (MusicContext) instead.")
    public var latestFrame: VisualizerFrame {
        VisualizerFrame(sound: latestSound, music: latestMusic, previousHits: previousHits)
    }
    /// Called on the main actor every ~17 ms; returns the notes for all steps up to `throughStep`.
    @ObservationIgnored public var noteProvider: (@MainActor (_ throughStep: Int) -> [ScheduledNote])?
    /// 0 ... 1
    public var masterVolume: Float = 0.8 {
        didSet { core?.setMasterVolume(min(max(masterVolume, 0), 1)) }
    }

    /// The iOS audio-session setup `start()` applies. Set it before `start()`; ignored on macOS.
    public var sessionMode: SessionMode = .playback

    public private(set) var isRecording = false
    public private(set) var gains: [MixerChannel: Float] = [.drums: 1, .bass: 1, .fx: 1]
    public private(set) var mutes: Set<MixerChannel> = []

    #if os(macOS)
        /// How far ahead of the render position notes are scheduled.
        public static let lookaheadSeconds = 0.1
    #else
        /// How far ahead of the render position notes are scheduled. Raised off macOS: the pump rides the main run
        /// loop, which a busy SwiftUI frame, a sheet or a scroll can hold up for longer than 100 ms.
        public static let lookaheadSeconds = 0.25
    #endif
    /// The timer period of the note pump and analysis frames.
    public static let frameInterval = 1.0 / 60

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var core: DropSynthCore?
    @ObservationIgnored private var analyzer: SoundAnalyzer?
    @ObservationIgnored private var analysisScratch = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scheduledThrough = -1
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: DropRecorder?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var pausedByInterruption = false

    public init(settings: SongSettings = SongSettings()) {
        self.settings = settings
    }

    // MARK: Mixer

    public func gain(for channel: MixerChannel) -> Float {
        gains[channel] ?? 1
    }

    public func setGain(_ gain: Float, for channel: MixerChannel) {
        let clamped = min(max(gain.isFinite ? gain : 0, 0), 1.5)
        gains[channel] = clamped
        core?.setGain(clamped, for: channel.bus)
    }

    public func setMuted(_ muted: Bool, for channel: MixerChannel) {
        if muted { mutes.insert(channel) } else { mutes.remove(channel) }
        core?.setMuted(muted, for: channel.bus)
    }

    // MARK: Transport

    /// Builds the graph at the output device's sample rate and starts playing from step 0.
    public func start() throws {
        guard !isRunning else { return }
        stopTask?.cancel()
        stopTask = nil
        if engine.isRunning { engine.stop() }
        try activateAudioSession()
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }

        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw DropEngineError.noOutputFormat
        }

        let core = DropSynthCore(sampleRate: sampleRate, bpm: settings.bpm, stepsPerBar: settings.stepsPerBar)
        for channel in MixerChannel.allCases {
            core.setGain(gain(for: channel), for: channel.bus)
            core.setMuted(mutes.contains(channel), for: channel.bus)
        }
        core.setMasterVolume(min(max(masterVolume, 0), 1))

        let node = AVAudioSourceNode(format: format, renderBlock: DropEngine.makeRenderBlock(core))
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()

        self.core = core
        sourceNode = node
        if analyzer?.sampleRate != sampleRate { analyzer = SoundAnalyzer(sampleRate: sampleRate) }
        scheduledThrough = -1
        currentStep = 0
        hitBase = latestMusic.hitCounts
        pumpNotes()  // fill the first look-ahead window before the first render callback

        do {
            try engine.start()
        } catch {
            engine.detach(node)
            sourceNode = nil
            self.core = nil
            throw error
        }
        isRunning = true
        observeConfigurationChanges()
        startTimer()
    }

    /// Fades out over 30 ms, then stops the engine: no click.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        core?.beginFadeOut()
        stopTask?.cancel()
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, !self.isRunning else { return }
            self.engine.stop()
            self.latestSound = SoundFrame(sequence: self.latestSound.sequence &+ 1, time: self.latestSound.time)
            self.latestMusic = self.musicContext(core: nil, hitCounts: self.latestMusic.hitCounts)
        }
    }

    // MARK: Recording

    /// Records the master bus to an AAC `.m4a` at `url` until `stopRecording()`.
    public func startRecording(to url: URL) throws {
        guard isRunning else { throw DropEngineError.notRunning }
        guard recorder == nil else { throw DropEngineError.alreadyRecording }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        let recorder = try DropRecorder(url: url, format: format)
        mixer.installTap(onBus: 0, bufferSize: 4_096, format: format, block: recorder.makeTapBlock())
        self.recorder = recorder
        isRecording = true
    }

    /// Finishes the file and returns its URL (nil if nothing was recording or the file failed).
    public func stopRecording() async -> URL? {
        guard let recorder else { return nil }
        engine.mainMixerNode.removeTap(onBus: 0)
        self.recorder = nil
        isRecording = false
        return await Task.detached { recorder.finish() }.value
    }

    // MARK: Sound source

    /// A `SoundFrameSource` over the running synth's output, for any NardukSoundAnalysis consumer; poll it on the
    /// visualizer's clock. It reads this `start()`'s synth, so ask again after a restart. Nil while stopped.
    public func makeSoundSource() -> (any SoundFrameSource)? {
        guard isRunning, let core else { return nil }
        return RecentSamplesSource(sampleRate: core.sampleRate) { core.copyRecentSamples(into: $0) }
    }

    // MARK: Timer: note pump + analysis

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: DropEngine.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isRunning, let core else { return }
        let secondsPerStep = settings.secondsPerStep
        let latency = engine.outputNode.presentationLatency + Double(core.lastBufferFrames) / core.sampleRate
        let audible = max(core.renderedStepPosition - latency / secondsPerStep, 0)
        let step = Int(audible)
        if step != currentStep { currentStep = step }
        pumpNotes()
        publishFrame(core: core)
    }

    private func pumpNotes() {
        guard let core, let noteProvider else { return }
        let secondsPerStep = settings.secondsPerStep
        let through = Int(core.renderedStepPosition + DropEngine.lookaheadSeconds / secondsPerStep)
        guard through > scheduledThrough else { return }
        // The core drops anything that arrives more than a step late.
        for note in noteProvider(through) { core.schedule(note) }
        scheduledThrough = through
    }

    private func publishFrame(core: DropSynthCore) {
        guard let analyzer else { return }
        let time = Double(core.renderedSampleCount) / core.sampleRate
        analysisScratch.withUnsafeMutableBufferPointer { core.copyRecentSamples(into: $0) }
        latestSound = analysisScratch.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
        previousHits = latestMusic.hitCounts
        var counts = core.hitCounters
        counts.lanes &+= hitBase.lanes
        latestMusic = musicContext(core: core, hitCounts: counts)
    }

    /// The music's side of a frame. `core` is nil once stopped: the clock and counters hold, the wobble rests.
    private func musicContext(core: DropSynthCore?, hitCounts: HitCounters) -> MusicContext {
        let stepsPerPhrase = max(settings.stepsPerPhrase, 1)
        return MusicContext(
            hitCounts: hitCounts, step: currentStep, section: section, energy: Float(conductor.energy),
            wobblePhase: core?.wobblePhase ?? 0, wobbleCutoff: core?.wobbleCutoff ?? 0, isRunning: core != nil,
            secondsPerStep: settings.secondsPerStep, stepsPerBar: settings.stepsPerBar, stepsPerPhrase: stepsPerPhrase,
            phraseProgress: Float(currentStep % stepsPerPhrase) / Float(stepsPerPhrase),
            buildThreshold: Float(conductor.buildThreshold), dropThreshold: Float(conductor.dropThreshold),
            dropQueued: conductor.dropQueued)
    }

    // MARK: Device changes

    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The output device or its sample rate changed: rebuild the graph and carry on.
                guard let self, self.isRunning else { return }
                self.isRunning = false
                self.timer?.invalidate()
                self.timer = nil
                try? self.start()
            }
        }
    }

    // MARK: Render block (built outside the main actor so it carries no actor isolation)

    nonisolated private static func makeRenderBlock(_ core: DropSynthCore) -> AVAudioSourceNodeRenderBlock {
        // The engine keeps `core` alive for as long as this node can render; unowned(unsafe)
        // keeps reference counting off the render thread.
        unowned(unsafe) let synth = core
        return { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
            synth.render(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }
}

// MARK: iOS audio session

extension DropEngine {
    /// Sets the category, activates the session (before the hardware format is read) and listens for interruptions
    /// and unplugged outputs. A no-op on macOS.
    fileprivate func activateAudioSession() throws {
        #if !os(macOS)
            let session = AVAudioSession.sharedInstance()
            switch sessionMode {
            case .playback:
                try session.setCategory(.playback, mode: .default)
            case .playAndRecord:
                try session.setCategory(
                    .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            }
            try session.setActive(true)
            observeAudioSession(session)
        #endif
    }

    #if !os(macOS)
        private func observeAudioSession(_ session: AVAudioSession) {
            guard sessionObservers.isEmpty else { return }
            let center = NotificationCenter.default
            sessionObservers.append(
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification, object: session, queue: .main
                ) { [weak self] note in
                    let began =
                        (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                        == AVAudioSession.InterruptionType.began.rawValue
                    let options = AVAudioSession.InterruptionOptions(
                        rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    MainActor.assumeIsolated {
                        self?.handleInterruption(began: began, shouldResume: options.contains(.shouldResume))
                    }
                })
            sessionObservers.append(
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
                ) { [weak self] note in
                    let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    // Headphones pulled out: stop rather than blast the speaker.
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                    MainActor.assumeIsolated { self?.stop() }
                })
        }
    #endif

    fileprivate func handleInterruption(began: Bool, shouldResume: Bool) {
        switch InterruptionResponse.response(
            began: began, shouldResume: shouldResume, wasRunning: isRunning,
            pausedByInterruption: pausedByInterruption)
        {
        case .pause:
            pausedByInterruption = true
            stop()
        case .resume:
            pausedByInterruption = false
            try? start()
        case .none:
            if !began { pausedByInterruption = false }
        }
    }
}
