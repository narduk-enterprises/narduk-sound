import AVFoundation
import CoreAudio
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
/// Notes: a `ConductorDriver` (`play(_:)`) is pumped from its own thread after every rendered buffer, so the song keeps
/// writing with the screen off; its steps never go backwards. The older `noteProvider` is asked on a ~60 Hz main-actor
/// timer instead, and its steps restart at 0 on every `start()`. Either way notes reach the synth through a lock-free
/// ring ~100 ms ahead of the render position.
/// Main actor side: the timer publishes `latestSound` and `latestMusic`.
/// Render side: the source node calls `DropSynthCore.render`, which never allocates or locks.
@MainActor @Observable public final class DropEngine {
    /// BPM changes apply at the next bar. With a driver attached, the settings follow the genre and tempo the listener
    /// hears, and a BPM set here goes to the driver.
    public var settings: SongSettings {
        didSet {
            guard !followingDriver else { return }
            if let driver {
                if settings.bpm != oldValue.bpm { driver.setTempo(settings.bpm) }
            } else {
                core?.setTempo(settings.bpm)
            }
        }
    }
    /// Set while the engine echoes the driver into `settings`, so the echo is never sent back as a tempo request (a
    /// stale one would retarget a switch already on its way).
    @ObservationIgnored private var followingDriver = false

    public private(set) var isRunning = false
    /// True between `pause()` and `resume()`; the song keeps its place and `isRunning` stays true.
    public private(set) var isPaused = false
    /// The step currently audible (output-latency compensated). With a driver it is the song's step, which never goes
    /// backwards; with `noteProvider` it restarts at 0 on every `start()`.
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
    /// The synth's one producer: every push into its event ring holds this lock, which also tracks the pitched notes
    /// handed to the synth against the audible step position, so `latestMusic` can say which notes are sounding. The
    /// render thread never takes it.
    @ObservationIgnored private let feed = NoteFeed()
    @ObservationIgnored private var audibleStepPosition: Double = 0

    /// The pre-0.4.0 frame, built from `latestSound` and `latestMusic`; its `hits` are the instruments that fired since
    /// the previous publish.
    @available(*, deprecated, message: "Read latestSound (SoundFrame) and latestMusic (MusicContext) instead.")
    public var latestFrame: VisualizerFrame {
        VisualizerFrame(sound: latestSound, music: latestMusic, previousHits: previousHits)
    }
    /// Called on the main actor every ~17 ms; returns the notes for all steps up to `throughStep`. Superseded by
    /// `driver`, which wins when both are set.
    @ObservationIgnored public var noteProvider: (@MainActor (_ throughStep: Int) -> [ScheduledNote])?
    /// The live pump (narduk-sound#5): writes the song from its own thread, paced by the audio clock, and applies its
    /// tempo switches on their bar. Set it before `start()`, or use `play(_:)`. Replacing it while playing starts the
    /// new driver's song at the next bar line.
    @ObservationIgnored public var driver: ConductorDriver? {
        didSet {
            guard driver !== oldValue, isRunning else { return }
            startLivePump()
            if livePump == nil { pumpNotes() }
        }
    }
    /// Signalled by the render block after every buffer; the live pump waits on it.
    @ObservationIgnored private let pumpWake = PumpWake()
    @ObservationIgnored private var livePump: LivePump?
    /// Sweeps the master filter over the whole mix (`MasterFilter.idle` bypasses it, bit for bit). A DROP's build drives it
    /// from `DropArranger.filterSweep` each frame and sets `.idle` on the release, which snaps it open in about 60 ms.
    public func setMasterFilter(_ filter: MasterFilter) { core?.setMasterFilter(filter) }

    /// 0 ... 1
    public var masterVolume: Float = 0.8 {
        didSet { core?.setMasterVolume(min(max(masterVolume, 0), 1)) }
    }

    /// Mutes what reaches the speaker and nothing else: the recording and the `SoundFrameSource` keep the full signal.
    /// For a headless run that must verify recording and the meters without making a sound (Beat Blaster's
    /// `-silent YES`). Unlike `masterVolume`, which scales the synth itself, this acts after the capture point. False
    /// (the default) leaves the output as it was. Takes effect at once, also while playing.
    public var mutesHardwareOutput = false {
        didSet { applyHardwareVolume() }
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
    /// Where the synth lands before the output stage: the recording taps it, so `mutesHardwareOutput` can silence the
    /// main mixer (the speaker path) without silencing the capture. Graph: source -> capture mixer -> main mixer -> out.
    @ObservationIgnored private let captureMixer = AVAudioMixerNode()
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

    // MARK: Cuts

    /// Chops the song now: a beat repeat (`.stutter`), trance `.gate`, `.reverse` slice or re-sliced `.chop` of
    /// `division` slices for `steps` sixteenths, from the next audio buffer, then the song comes back. For a live
    /// "STUTTER" button (narduk-libs#1641). Returns false when the engine is stopped or the event ring is full.
    @discardableResult
    public func cut(
        _ mode: CutMode = .stutter, division: CutDivision = .sixteenth, steps: Int = 4, amount: Double = 0.5,
        seed: Int = 0
    ) -> Bool {
        guard let core else { return false }
        return feed.produce { core.cut(mode, division: division, steps: steps, amount: amount, seed: seed) }
    }

    // MARK: Drop tie-in

    /// Schedules the sampled-voice riser (`VocalFX.riser`) that climbs into `dropStep`, an absolute song step. For a
    /// drop arranger: call it a bar or two ahead. Notes already in the past are dropped by the core. Returns the
    /// number scheduled, 0 when the engine is stopped.
    @discardableResult
    public func scheduleVocalRiser(
        intoDropAt dropStep: Int, steps: Int = 16, pitch: Int = 67, vowel: VocalVowel = .ah
    ) -> Int {
        schedule(VocalFX.riser(endStep: dropStep, steps: steps, pitch: pitch, vowel: vowel))
    }

    /// Schedules the stutter that tightens (eighth, sixteenth, thirty-second) into `dropStep`, an absolute song step.
    @discardableResult
    public func scheduleStutterIntoDrop(at dropStep: Int, beats: Int = 1, seed: Int = 0) -> Int {
        schedule(VocalFX.stutterIntoDrop(dropStep: dropStep, beats: beats, seed: seed))
    }

    private func schedule(_ notes: [ScheduledNote]) -> Int {
        guard let core else { return 0 }
        // Song steps (what a driver's snapshot reports) to the synth's clock.
        let origin = driver?.origin ?? 0
        let moved =
            origin == 0
            ? notes
            : notes.map { note in
                var note = note
                note.step -= origin
                return note
            }
        feed.push(moved, to: core, track: false)
        return notes.count
    }

    // MARK: Transport

    /// Plays `driver`: attaches it, then starts the engine, or resumes it when paused.
    public func play(_ driver: ConductorDriver) throws {
        if self.driver !== driver { self.driver = driver }
        if !isRunning {
            try start()
        } else if isPaused {
            try resume()
        }
    }

    /// Builds the graph at the output device's sample rate and starts playing: a driver's song carries on from its next
    /// bar line, a `noteProvider` from step 0.
    public func start() throws {
        guard !isRunning else { return }
        livePump?.cancel()
        livePump = nil
        stopTask?.cancel()
        stopTask = nil
        if engine.isRunning { engine.stop() }
        try activateAudioSession()
        if let node = sourceNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sourceNode = nil
        }

        let sampleRate: Double
        if let offline = offlineFormat {
            // Tests: the graph is pulled by `renderOffline(frames:)`, so no output device is needed or touched.
            try engine.enableManualRenderingMode(.offline, format: offline, maximumFrameCount: Self.offlineSliceFrames)
            sampleRate = offline.sampleRate
        } else {
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : 48_000
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw DropEngineError.noOutputFormat
        }

        let core = DropSynthCore(
            sampleRate: sampleRate, bpm: driver?.startTempo ?? settings.bpm, stepsPerBar: settings.stepsPerBar)
        for channel in MixerChannel.allCases {
            core.setGain(gain(for: channel), for: channel.bus)
            core.setMuted(mutes.contains(channel), for: channel.bus)
        }
        core.setMasterVolume(min(max(masterVolume, 0), 1))

        let node = AVAudioSourceNode(format: format, renderBlock: DropEngine.makeRenderBlock(core, wake: pumpWake))
        engine.attach(node)
        if captureMixer.engine == nil { engine.attach(captureMixer) }
        engine.connect(node, to: captureMixer, format: format)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: format)
        applyHardwareVolume()
        engine.prepare()

        self.core = core
        sourceNode = node
        if analyzer?.sampleRate != sampleRate { analyzer = SoundAnalyzer(sampleRate: sampleRate) }
        scheduledThrough = -1
        hitBase = latestMusic.hitCounts
        // Fresh synth, fresh notes; the counters carry on so a consumer's diff never sees a jump back.
        feed.reset()
        audibleStepPosition = 0
        pumpNotes()  // fill the first look-ahead window before the first render callback
        currentStep = max(driver?.origin ?? 0, 0)  // a driver's song carries on: the step never goes back to 0

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
        startLivePump()
        startTimer()
    }

    /// Holds the song where it is: the audio engine pauses (the render thread stops, so the playhead and the synth's
    /// state freeze) and the published frame stays the last one. `resume()` carries on from the same step.
    public func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        timer?.invalidate()
        timer = nil
        engine.pause()
    }

    public func resume() throws {
        guard isRunning, isPaused else { return }
        try engine.start()
        isPaused = false
        startTimer()
    }

    /// Fades out over 30 ms, then stops the engine: no click.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        isPaused = false
        timer?.invalidate()
        timer = nil
        livePump?.cancel()
        livePump = nil
        feed.reset()
        core?.beginFadeOut()
        stopTask?.cancel()
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, !self.isRunning else { return }
            self.engine.stop()
            self.latestSound = SoundFrame(sequence: self.latestSound.sequence &+ 1, time: self.latestSound.time)
            self.latestMusic = self.musicContext(
                core: nil, hitCounts: self.latestMusic.hitCounts, notes: (NoteSet(), self.latestMusic.noteCounts))
        }
    }

    /// The speaker path's volume: 0 when muted, else 1 (the main mixer is not a user-facing volume).
    private func applyHardwareVolume() {
        engine.mainMixerNode.outputVolume = mutesHardwareOutput ? 0 : 1
    }

    /// The main mixer's output volume, for tests.
    var hardwareVolume: Float { engine.mainMixerNode.outputVolume }

    /// Set before `start()` to run the graph in manual offline rendering, pulled by `renderOffline(frames:)`
    /// instead of an output device, so a test is the same on a laptop and a CI runner with no live audio.
    @ObservationIgnored var offlineFormat: AVAudioFormat?
    static let offlineSliceFrames: AVAudioFrameCount = 1_024

    /// Renders `frames` through the whole graph (main mixer output, so `mutesHardwareOutput` applies), running the
    /// note pump (a driver's too: no pump thread runs offline) and analysis between slices as the timer would. Returns
    /// what the speaker would have received.
    func renderOffline(frames: Int) throws -> AVAudioPCMBuffer {
        guard offlineFormat != nil, isRunning else { throw DropEngineError.notRunning }
        let format = engine.manualRenderingFormat
        guard
            let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.offlineSliceFrames),
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw DropEngineError.noOutputFormat }
        while Int(output.frameLength) < frames {
            tick()
            let count = min(Self.offlineSliceFrames, AVAudioFrameCount(frames) - output.frameLength)
            let status = try engine.renderOffline(count, to: slice)
            guard status == .success else { throw DropEngineError.noOutputFormat }
            for channel in 0..<Int(format.channelCount) {
                guard let from = slice.floatChannelData?[channel], let to = output.floatChannelData?[channel] else {
                    continue
                }
                (to + Int(output.frameLength)).update(from: from, count: Int(slice.frameLength))
            }
            output.frameLength += slice.frameLength
        }
        return output
    }

    // MARK: Recording

    /// Records the synth's output to an AAC `.m4a` at `url` until `stopRecording()`, at full level also while
    /// `mutesHardwareOutput` is on.
    public func startRecording(to url: URL) throws {
        guard isRunning else { throw DropEngineError.notRunning }
        guard recorder == nil else { throw DropEngineError.alreadyRecording }
        let mixer = captureMixer
        let format = mixer.outputFormat(forBus: 0)
        let recorder = try DropRecorder(url: url, format: format)
        mixer.installTap(onBus: 0, bufferSize: 4_096, format: format, block: recorder.makeTapBlock())
        self.recorder = recorder
        isRecording = true
    }

    /// Finishes the file and returns its URL (nil if nothing was recording or the file failed).
    public func stopRecording() async -> URL? {
        guard let recorder else { return nil }
        captureMixer.removeTap(onBus: 0)
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
        audibleStepPosition = audible
        // A driver's origin maps the synth's steps onto the song (negative while a newly swapped-in song waits for
        // its first bar line).
        let step = max(Int(audible) + (driver?.origin ?? 0), 0)
        if step != currentStep { currentStep = step }
        if livePump == nil { pumpNotes() }
        if let driver { follow(driver) }
        publishFrame(core: core)
    }

    /// Starts the pump thread for a live (not offline) run with a driver.
    private func startLivePump() {
        livePump?.cancel()
        livePump = nil
        guard isRunning, offlineFormat == nil, let driver, let core else { return }
        livePump = LivePump(wake: pumpWake) { [feed] in feed.pump(driver, into: core) }
    }

    /// Echoes what the listener hears into `section`, `conductor` and `settings`.
    private func follow(_ driver: ConductorDriver) {
        let status = driver.status
        let heard = status.heard(atStep: currentStep)
        if section != status.section { section = status.section }
        conductor = status.snapshot
        if settings.genre != heard.genre || settings.bpm != heard.bpm {
            followingDriver = true
            settings.genre = heard.genre
            settings.bpm = heard.bpm
            followingDriver = false
        }
    }

    private func pumpNotes() {
        guard let core else { return }
        if let driver {
            feed.pump(driver, into: core)
            return
        }
        guard let noteProvider else { return }
        let secondsPerStep = settings.secondsPerStep
        let through = Int(core.renderedStepPosition + DropEngine.lookaheadSeconds / secondsPerStep)
        guard through > scheduledThrough else { return }
        // The core drops anything that arrives more than a step late.
        feed.push(noteProvider(through), to: core)
        scheduledThrough = through
    }

    private func publishFrame(core: DropSynthCore) {
        guard let analyzer else { return }
        let time = Double(core.renderedSampleCount) / core.sampleRate
        analysisScratch.withUnsafeMutableBufferPointer { core.copyRecentSamples(into: $0) }
        latestSound = analysisScratch.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
        previousHits = latestMusic.hitCounts
        let notes = feed.advance(to: audibleStepPosition)
        var counts = core.hitCounters
        counts.lanes &+= hitBase.lanes
        latestMusic = musicContext(core: core, hitCounts: counts, notes: notes)
    }

    /// The music's side of a frame. `core` is nil once stopped: the clock and counters hold, the wobble rests.
    private func musicContext(
        core: DropSynthCore?, hitCounts: HitCounters, notes: (held: NoteSet, counters: NoteCounters)
    ) -> MusicContext {
        let stepsPerPhrase = max(settings.stepsPerPhrase, 1)
        return MusicContext(
            hitCounts: hitCounts, step: currentStep, section: section, energy: Float(conductor.energy),
            wobblePhase: core?.wobblePhase ?? 0, wobbleCutoff: core?.wobbleCutoff ?? 0, isRunning: core != nil,
            secondsPerStep: settings.secondsPerStep, stepsPerBar: settings.stepsPerBar, stepsPerPhrase: stepsPerPhrase,
            phraseProgress: Float(currentStep % stepsPerPhrase) / Float(stepsPerPhrase),
            buildThreshold: Float(conductor.buildThreshold), dropThreshold: Float(conductor.dropThreshold),
            dropQueued: conductor.dropQueued, heldNotes: notes.held, noteCounts: notes.counters)
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
                try? self.start()  // a driver carries on from its next bar line on the new synth
            }
        }
    }

    // MARK: Render block (built outside the main actor so it carries no actor isolation)

    /// Renders `core` and then signals `wake`, which paces the driver's pump thread.
    nonisolated static func makeRenderBlock(_ core: DropSynthCore, wake: PumpWake) -> AVAudioSourceNodeRenderBlock {
        // The engine keeps `core` and `wake` alive for as long as this node can render; unowned(unsafe)
        // keeps reference counting off the render thread.
        unowned(unsafe) let synth = core
        unowned(unsafe) let alarm = wake
        return { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
            synth.render(frames: Int(frameCount), left: left, right: right)
            alarm.signal()
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
