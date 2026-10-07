import Foundation
import MediaPlayer

/// What the lock screen, Control Center and a HomePod show about the music that is playing.
///
/// A plain value: build one from the conductor's state whenever the track, the genre or the play state changes, and
/// hand it to `NowPlayingBridge.update(_:)`. The system extrapolates the elapsed time from `elapsed` and the rate, so
/// no per-frame or per-second update is needed (and none should be sent).
public struct NowPlayingSnapshot: Sendable, Equatable {
    /// The title line, for example the generated track's name.
    public var title: String
    /// The artist line (an app might put the genre and key here, or its own name).
    public var artist: String?
    /// The genre, shown by the system where it shows one.
    public var genre: String?
    /// Seconds since the track began.
    public var elapsed: TimeInterval
    /// Seconds in the track, or `nil` for the endless stream, which the system shows as live.
    public var duration: TimeInterval?
    /// Whether the music is sounding now.
    public var isPlaying: Bool
    /// The rate the clock runs at while playing (1 unless the tempo is being scaled against the clock).
    public var playbackRate: Double

    public init(
        title: String, artist: String? = nil, genre: String? = nil, elapsed: TimeInterval = 0,
        duration: TimeInterval? = nil, isPlaying: Bool = true, playbackRate: Double = 1
    ) {
        self.title = title
        self.artist = artist
        self.genre = genre
        self.elapsed = elapsed
        self.duration = duration
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
    }

    /// The rate the system advances the elapsed time at: 0 when paused, so the lock screen scrubber stops.
    public var effectiveRate: Double { isPlaying ? playbackRate : 0 }

    /// The `MPNowPlayingInfoCenter` dictionary for this snapshot. Pure: no system object is touched.
    public var infoDictionary: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyIsLiveStream: duration == nil,
        ]
        if let artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let genre, !genre.isEmpty { info[MPMediaItemPropertyGenre] = genre }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = max(0, duration) }
        return info
    }

    /// The playback state the system shows beside the info (macOS reads it, iOS uses it for route handoff).
    public var playbackState: MPNowPlayingPlaybackState { isPlaying ? .playing : .paused }
}
