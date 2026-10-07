import AVFoundation
import Foundation
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

    /// The state every `NardukSoundVisuals` card draws from. One state for the whole gallery: `update` is idempotent per
    /// display frame, and each card polling for itself would smooth the analyzer's output once per card.
    @ObservationIgnored let visualState = SoundVisualState()

    /// The latest frame at `date`; silence while nothing plays. Also advances `visualState` (no `MusicContext`: the
    /// gallery drives the visualizers from any source's frames alone, as the contract allows).
    func poll(at date: Date) -> SoundFrame {
        let now = date.timeIntervalSinceReferenceDate
        if let source {
            latest = source.poll(time: now - clockOrigin)
        } else {
            latest = SoundFrame()
        }
        visualState.update(SoundVisualInput(frame: latest), now: now)
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
        switch song.style {
        case .demo, .ambient:
            try drop.playDemo()
            status = "Playing the NardukMusic demo song."
        case .genre, .guitars:
            drop.settings = song.settings
            let player = SongPlayer(song: song, engine: drop)
            drop.noteProvider = { [player] throughStep in player.notes(through: throughStep) }
            try drop.start()
            status = "Playing \(song.style.title.lowercased()), seed \(song.seed % 10_000)."
        }
        source = drop.makeSoundSource()
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
