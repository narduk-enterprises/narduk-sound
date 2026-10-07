import Foundation
import MediaPlayer

/// `RemoteCommandInstalling` over the shared `MPRemoteCommandCenter`: play, pause, toggle and next track.
@MainActor final class SystemRemoteCommands: RemoteCommandInstalling {
    private var tokens: [(command: MPRemoteCommand, token: Any)] = []

    func install(supportsNext: Bool, handler: @escaping @MainActor (RemoteCommand) -> MPRemoteCommandHandlerStatus) {
        uninstall()
        let center = MPRemoteCommandCenter.shared()
        let routes: [(MPRemoteCommand, RemoteCommand, Bool)] = [
            (center.playCommand, .play, true),
            (center.pauseCommand, .pause, true),
            (center.togglePlayPauseCommand, .togglePlayPause, true),
            (center.nextTrackCommand, .nextTrack, supportsNext),
        ]
        for (command, remote, enabled) in routes {
            command.isEnabled = enabled
            // The system may call this on any thread; the transport is main-actor, so hop there.
            let token = command.addTarget { _ in
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { handler(remote) }
                }
                return DispatchQueue.main.sync { MainActor.assumeIsolated { handler(remote) } }
            }
            tokens.append((command, token))
        }
    }

    func uninstall() {
        for (command, token) in tokens {
            command.removeTarget(token)
            command.isEnabled = false
        }
        tokens.removeAll()
    }
}
