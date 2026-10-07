import MediaPlayer

/// What the lock screen and a HomePod can ask of the music. The conductor driver (or an app's own player) conforms;
/// this package defines no engine type, so nothing in `NardukMusicEngine` links MediaPlayer.
@MainActor public protocol NowPlayingTransport: AnyObject {
    /// Whether the music is sounding now.
    var isPlaying: Bool { get }
    /// Whether `next()` does anything (a fixed single track has no next). Defaults to true.
    var supportsNext: Bool { get }
    func play()
    func pause()
    func next()
}

extension NowPlayingTransport {
    public var supportsNext: Bool { true }
}

/// A transport command from the system, independent of `MPRemoteCommandCenter` so it is testable without it.
public enum RemoteCommand: Sendable, Equatable, CaseIterable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
}
