import MediaPlayer

/// Where the bridge publishes the Now Playing info; `MPNowPlayingInfoCenter` in the app, a fake in tests.
@MainActor public protocol NowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoPublishing {}

/// Where the bridge installs its remote-command handler; `MPRemoteCommandCenter` in the app, a fake in tests.
@MainActor public protocol RemoteCommandInstalling: AnyObject {
    /// Routes every supported command to `handler` and shows the controls. `supportsNext` enables or hides Next.
    func install(supportsNext: Bool, handler: @escaping @MainActor (RemoteCommand) -> MPRemoteCommandHandlerStatus)
    /// Removes the handler and hides the controls.
    func uninstall()
}

/// Maps `MPRemoteCommandCenter` to a `NowPlayingTransport` and publishes `NowPlayingSnapshot`s.
///
/// ```swift
/// let bridge = NowPlayingBridge()
/// bridge.start(transport: driver)            // lock screen and HomePod controls now work
/// bridge.update(NowPlayingSnapshot(title: "Night Drive", genre: "Synthwave"))
/// // on a track, genre or play-state change: bridge.update(...) again
/// bridge.stop()                              // clears Now Playing and removes the handlers
/// ```
///
/// Background playback also needs `UIBackgroundModes: audio` in the app's Info.plist (see `docs/now-playing.md`).
@MainActor public final class NowPlayingBridge {
    private let center: any NowPlayingInfoPublishing
    private let commands: any RemoteCommandInstalling
    private weak var transport: (any NowPlayingTransport)?

    /// The last snapshot published, or `nil` before the first update and after `stop()`.
    public private(set) var snapshot: NowPlayingSnapshot?
    /// True between `start(transport:)` and `stop()`.
    public private(set) var isActive = false

    public init() {
        center = MPNowPlayingInfoCenter.default()
        commands = SystemRemoteCommands()
    }

    /// Injection point for tests.
    init(center: any NowPlayingInfoPublishing, commands: any RemoteCommandInstalling) {
        self.center = center
        self.commands = commands
    }

    /// Installs the remote commands, routing them to `transport` (held weakly: the bridge never keeps the player
    /// alive). Calling it again re-points the commands.
    public func start(transport: any NowPlayingTransport) {
        self.transport = transport
        isActive = true
        commands.install(supportsNext: transport.supportsNext) { [weak self] command in
            self?.handle(command) ?? .noActionableNowPlayingItem
        }
    }

    /// Publishes `snapshot` to the lock screen, Control Center and AirPlay receivers.
    public func update(_ snapshot: NowPlayingSnapshot) {
        self.snapshot = snapshot
        center.nowPlayingInfo = snapshot.infoDictionary
        center.playbackState = snapshot.playbackState
    }

    /// Clears Now Playing and removes the remote-command handlers. Safe to call when not started.
    public func stop() {
        isActive = false
        snapshot = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        commands.uninstall()
    }

    /// Runs one system command against the transport and returns the status the system expects.
    func handle(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard isActive, let transport else { return .noActionableNowPlayingItem }
        switch command {
        case .play:
            if !transport.isPlaying { transport.play() }
        case .pause:
            if transport.isPlaying { transport.pause() }
        case .togglePlayPause:
            if transport.isPlaying { transport.pause() } else { transport.play() }
        case .nextTrack:
            guard transport.supportsNext else { return .commandFailed }
            transport.next()
        }
        return .success
    }
}
