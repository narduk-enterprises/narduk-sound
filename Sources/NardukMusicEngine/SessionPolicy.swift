/// How the engine sets up the shared audio session on iOS (ignored on macOS, which has none). `.playback` is the
/// long-form audio policy on iOS: AirPlay 2 multi-room, a HomePod group, background playback.
public enum SessionMode: Sendable, Equatable {
    /// Output only: the music plays, mixes with nothing else on the system, and shares to AirPlay 2 routes as long-form
    /// audio (the app needs `UIBackgroundModes: audio`).
    case playback
    /// Output and microphone input (the mic needs `playAndRecord`), mixing with other audio, speaker by default.
    case playAndRecord
}

/// What the engine does on an audio-session interruption (a call, Siri, an alarm); pure so it is testable anywhere.
enum InterruptionResponse: Equatable {
    case pause
    case resume
    case none

    /// `began` is true for an interruption starting, false for one ending. `shouldResume` is the system's hint on
    /// an ending; `wasRunning` and `pausedByInterruption` are the engine's own state.
    static func response(
        began: Bool, shouldResume: Bool, wasRunning: Bool, pausedByInterruption: Bool
    ) -> InterruptionResponse {
        if began { return wasRunning ? .pause : .none }
        return pausedByInterruption && shouldResume ? .resume : .none
    }
}

/// Why the audio route changed; the pure mirror of `AVAudioSession.RouteChangeReason` (whose raw values are stable
/// API), so the reroute policy is testable on a Mac.
enum RouteChangeReason: Equatable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange

    init(rawValue: UInt?) {
        switch rawValue {
        case 1: self = .newDeviceAvailable
        case 2: self = .oldDeviceUnavailable
        case 3: self = .categoryChange
        case 4: self = .override
        case 6: self = .wakeFromSleep
        case 7: self = .noSuitableRouteForCategory
        case 8: self = .routeConfigurationChange
        default: self = .unknown
        }
    }
}

/// What the engine does when the audio route changes (headphones, AirPlay, Bluetooth, a HomePod group).
enum RouteChangeResponse: Equatable {
    /// Carry on: the song moves to the new output without a gap in its position.
    case keepPlaying
    /// Hold the song where it is (the cursor stays); the listener presses play.
    case pause

    /// The old output vanished (headphones unplugged, a speaker dropped off AirPlay): pause rather than blast the
    /// built-in speaker. Every other change, `routeConfigurationChange` and `newDeviceAvailable` included, keeps
    /// playing. A song already stopped or paused has nothing to hold.
    static func response(reason: RouteChangeReason, isRunning: Bool, isPaused: Bool) -> RouteChangeResponse {
        reason == .oldDeviceUnavailable && isRunning && !isPaused ? .pause : .keepPlaying
    }
}

/// What the engine does after the system has torn its audio graph down: an `AVAudioEngineConfigurationChange` (the
/// output device or its sample rate changed) or `mediaServicesWereReset` (the audio daemon restarted). In both the
/// song keeps its synth and its position; only the `AVAudioEngine` side is built again.
enum GraphRebuildResponse: Equatable {
    /// Nothing is loaded; there is no song to carry over.
    case none
    /// Rebuild the graph and start the engine again.
    case rebuildAndPlay
    /// Rebuild the graph but leave it stopped: the song was paused, and `resume()` carries on from the same step.
    case rebuildHeld

    static func response(isRunning: Bool, isPaused: Bool) -> GraphRebuildResponse {
        guard isRunning else { return .none }
        return isPaused ? .rebuildHeld : .rebuildAndPlay
    }
}
