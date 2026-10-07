import AVFoundation
import Foundation
import NardukMusicCore
import NardukMusicEngine
import NardukSoundAnalysis
import NardukSoundVisuals
import Observation

/// Where the sound comes from.
enum GalleryInput: String, CaseIterable, Identifiable {
    case demo = "Demo song"
    case microphone = "Microphone"
    case file = "File"

    var id: String { rawValue }
}

/// Owns the audio graph for the gallery and hands out frames. Frames are polled on the view's own clock and never
/// observed (`source` is ignored by Observation), so a new frame never invalidates a view body by itself.
@MainActor @Observable final class GalleryModel {
    var input: GalleryInput = .demo
    /// What the demo source plays (the picker sets it; `newSong()` rerolls the seed).
    var song = GallerySong()
    private(set) var isRunning = false
    /// Paused: the source holds its place and the cards keep their last frame, but still repaint on a color change.
    private(set) var isPaused = false
    /// True for a moment after the look changes, so a stopped or paused gallery keeps drawing until the ease ends.
    private(set) var repaintHold = false
    @ObservationIgnored private var repaintTask: Task<Void, Never>?
    private(set) var status = "Pick a source and press Play."

    @ObservationIgnored private var source: (any SoundFrameSource)?
    @ObservationIgnored private var latest = SoundFrame()
    @ObservationIgnored private let drop = DropEngine()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var tap: AudioTapSource?
    @ObservationIgnored private var fileAccess: URL?
    @ObservationIgnored private let clockOrigin = Date.timeIntervalSinceReferenceDate

    /// The frame the last `poll` returned, for a view that draws on its own clock (the Metal tunnel).
    var latestFrame: SoundFrame { latest }

    /// The engine's `MusicContext` while the demo song plays (hit counters, section, beat clock); nil for a
    /// microphone or file, which have no conductor. The visualizers treat nil as "not music".
    var latestMusic: MusicContext? { isRunning && input == .demo ? drop.latestMusic : nil }

    /// The frame and, for the demo song, its music: what every visualizer polls.
    var latestInput: SoundVisualInput { SoundVisualInput(frame: latest, music: latestMusic) }

    /// The state every `NardukSoundVisuals` card draws from. One state for the whole gallery: `update` is idempotent per
    /// display frame, and each card polling for itself would smooth the analyzer's output once per card.
    @ObservationIgnored let visualState = SoundVisualState()

    /// The palette preset behind `look` (the knobs layer on top of it); nil after a random roll.
    var preset: SoundPalettePreset? = .neon

    /// Colors and knobs for every card; mirrored onto the shared state, which every visualizer draws from.
    var look = SoundPaletteLook.neutral {
        didSet {
            visualState.look = look
            holdRepaint()
        }
    }

    private func holdRepaint() {
        repaintHold = true
        repaintTask?.cancel()
        repaintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { self?.repaintHold = false }
        }
    }

    /// Play/Pause as one toggle: a song or a file keeps its playhead; the microphone just freezes the picture.
    func togglePause() {
        guard isRunning else { return }
        if isPaused {
            do {
                try drop.resume()
            } catch {
                status = "Could not resume: \(error.localizedDescription)"
                return
            }
            player?.play()
            isPaused = false
        } else {
            drop.pause()
            player?.pause()
            isPaused = true
        }
    }

    /// Copies the gallery's look onto a tile's own state. Metal and spectacle tiles advance a private state on their own
    /// clocks, so the shared one's look never reaches them unless each tile syncs.
    func sync(_ state: SoundVisualState) {
        if state.look != look { state.look = look }
    }

    func choose(_ preset: SoundPalettePreset) {
        self.preset = preset
        look.colors = preset.colors
    }

    /// 🎲 A new harmonious palette; the knobs keep their positions.
    func rollRandom(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        preset = nil
        look.colors = SoundPaletteLook.random(seed: seed).colors
    }

    func resetLook() {
        preset = .neon
        look = .neutral
    }

    /// The latest frame at `date`; silence while nothing plays. Also advances `visualState` (with the demo song's
    /// `MusicContext`; other sources drive the visualizers from their frames alone, as the contract allows).
    func poll(at date: Date) -> SoundFrame {
        let now = date.timeIntervalSinceReferenceDate
        if isPaused {
            // Hold the last frame; the state still advances below so a color change eases in.
        } else if let source {
            latest = source.poll(time: now - clockOrigin)
        } else {
            latest = SoundFrame()
        }
        visualState.update(latestInput, now: now)
        return latest
    }

    func start(file url: URL? = nil) async {
        stop()
        do {
            switch input {
            case .demo: try startDemo()
            case .microphone: try await startMicrophone()
            case .file:
                guard let url else {
                    status = "Choose an audio file."
                    return
                }
                try startFile(url)
            }
            isRunning = true
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        isPaused = false
        drop.stop()
        player?.stop()
        tap?.stop()
        tap = nil
        if engine.isRunning { engine.stop() }
        if let player {
            engine.detach(player)
            self.player = nil
        }
        fileAccess?.stopAccessingSecurityScopedResource()
        fileAccess = nil
        source = nil
        isRunning = false
    }

    // MARK: Sources

    private func startDemo() throws {
        if song.style.playsClassicLoop {
            try drop.playDemo()
            status = "Playing the NardukMusic demo song."
        } else {
            drop.settings = song.settings
            let player = SongPlayer(song: song, engine: drop)
            drop.noteProvider = { [player] throughStep in player.notes(through: throughStep) }
            try drop.start()
            status = "Playing \(song.style.title.lowercased()), seed \(song.seed % 10_000)."
        }
        source = drop.makeSoundSource()
    }

    /// Plays a song a prompt wrote, replacing whatever plays now.
    func play(recipe: SongRecipe) {
        stop()
        input = .demo
        song = GallerySong(style: .recipe(recipe))
        Task { await start() }
    }

    /// A new seed for the current style; takes effect on the next play.
    func newSong() { song.reroll() }

    private func startMicrophone() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw GalleryError.microphoneDenied
        }
        #if os(iOS)
            try AudioSessionConfiguration.configureForMicrophone()
        #endif
        let tap = try AudioTapSource.microphone(of: engine)
        engine.prepare()
        try engine.start()
        try tap.start()
        self.tap = tap
        source = tap
        status = "Listening to the microphone."
    }

    private func startFile(_ url: URL) throws {
        if url.startAccessingSecurityScopedResource() { fileAccess = url }
        let file = try AVAudioFile(forReading: url)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        self.player = player
        Self.loop(file, on: player)
        engine.prepare()
        try engine.start()
        let tap = try AudioTapSource.mixer(of: engine)
        try tap.start()
        player.play()
        self.tap = tap
        source = tap
        status = "Playing \(url.lastPathComponent) on loop."
    }

    private nonisolated static func loop(_ file: AVAudioFile, on player: AVAudioPlayerNode) {
        player.scheduleFile(file, at: nil) { [weak player] in
            guard let player, player.isPlaying else { return }
            file.framePosition = 0
            loop(file, on: player)
        }
    }
}

enum GalleryError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access was denied. Allow it in Settings, or pick another source."
        }
    }
}
