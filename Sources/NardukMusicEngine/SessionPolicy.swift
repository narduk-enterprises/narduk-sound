/// How the engine sets up the shared audio session on iOS (ignored on macOS, which has none).
public enum SessionMode: Sendable, Equatable {
    /// Output only: the music plays, mixes with nothing else on the system.
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
