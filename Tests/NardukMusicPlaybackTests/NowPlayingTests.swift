import MediaPlayer
import Testing

@testable import NardukMusicPlayback

@MainActor final class FakeTransport: NowPlayingTransport {
    var isPlaying: Bool
    var supportsNext = true
    private(set) var calls: [String] = []

    init(isPlaying: Bool) { self.isPlaying = isPlaying }

    func play() {
        calls.append("play")
        isPlaying = true
    }

    func pause() {
        calls.append("pause")
        isPlaying = false
    }

    func next() { calls.append("next") }
}

@MainActor final class FakeCenter: NowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]?
    var playbackState = MPNowPlayingPlaybackState.unknown
}

@MainActor final class FakeCommands: RemoteCommandInstalling {
    private(set) var handler: (@MainActor (RemoteCommand) -> MPRemoteCommandHandlerStatus)?
    private(set) var supportsNext: Bool?
    private(set) var installs = 0
    private(set) var uninstalls = 0
    /// The handler holds the bridge weakly, as in the app; a test keeps it alive here.
    var owner: NowPlayingBridge?

    func install(supportsNext: Bool, handler: @escaping @MainActor (RemoteCommand) -> MPRemoteCommandHandlerStatus) {
        installs += 1
        self.supportsNext = supportsNext
        self.handler = handler
    }

    func uninstall() {
        uninstalls += 1
        handler = nil
    }

    /// Fires a command the way the system does, through the handler the bridge installed.
    func fire(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus? { handler?(command) }
}

@Suite struct NowPlayingInfoTests {
    @Test func theDictionaryCarriesTitleArtistGenreElapsedAndRate() {
        let snapshot = NowPlayingSnapshot(
            title: "Night Drive", artist: "Synthwave in A minor", genre: "Synthwave", elapsed: 42.5)
        let info = snapshot.infoDictionary
        #expect(info[MPMediaItemPropertyTitle] as? String == "Night Drive")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Synthwave in A minor")
        #expect(info[MPMediaItemPropertyGenre] as? String == "Synthwave")
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.audio.rawValue)
    }

    @Test func pausedMeansRateZeroSoTheScrubberStops() {
        let snapshot = NowPlayingSnapshot(title: "T", elapsed: 10, isPlaying: false)
        #expect(snapshot.infoDictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(snapshot.infoDictionary[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1)
        #expect(snapshot.playbackState == .paused)
        #expect(NowPlayingSnapshot(title: "T").playbackState == .playing)
    }

    @Test func aScaledClockRateIsPublishedWhilePlaying() {
        let snapshot = NowPlayingSnapshot(title: "T", playbackRate: 1.25)
        #expect(snapshot.infoDictionary[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.25)
    }

    @Test func noDurationIsALiveStreamAndADurationIsPublished() {
        let live = NowPlayingSnapshot(title: "T").infoDictionary
        #expect(live[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
        #expect(live[MPMediaItemPropertyPlaybackDuration] == nil)

        let fixed = NowPlayingSnapshot(title: "T", duration: 180).infoDictionary
        #expect(fixed[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
        #expect(fixed[MPMediaItemPropertyPlaybackDuration] as? Double == 180)
    }

    @Test func emptyOptionalLinesAreOmittedAndNegativeTimeClampsToZero() {
        let info = NowPlayingSnapshot(title: "T", artist: "", genre: nil, elapsed: -3).infoDictionary
        #expect(info[MPMediaItemPropertyArtist] == nil)
        #expect(info[MPMediaItemPropertyGenre] == nil)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
    }
}

@MainActor @Suite struct NowPlayingBridgeTests {
    private func makeBridge(playing: Bool) -> (NowPlayingBridge, FakeTransport, FakeCenter, FakeCommands) {
        let center = FakeCenter()
        let commands = FakeCommands()
        let transport = FakeTransport(isPlaying: playing)
        let bridge = NowPlayingBridge(center: center, commands: commands)
        bridge.start(transport: transport)
        commands.owner = bridge
        return (bridge, transport, center, commands)
    }

    @Test func playStartsAPausedTransportAndReturnsSuccess() {
        let (_, transport, _, commands) = makeBridge(playing: false)
        #expect(commands.fire(.play) == .success)
        #expect(transport.calls == ["play"])
    }

    @Test func pausePausesAPlayingTransportAndReturnsSuccess() {
        let (_, transport, _, commands) = makeBridge(playing: true)
        #expect(commands.fire(.pause) == .success)
        #expect(transport.calls == ["pause"])
    }

    @Test func playWhilePlayingAndPauseWhilePausedAreSuccessfulNoOps() {
        let (_, playing, _, playingCommands) = makeBridge(playing: true)
        #expect(playingCommands.fire(.play) == .success)
        #expect(playing.calls.isEmpty)
        let (_, paused, _, pausedCommands) = makeBridge(playing: false)
        #expect(pausedCommands.fire(.pause) == .success)
        #expect(paused.calls.isEmpty)
    }

    @Test func toggleFlipsTheTransportBothWays() {
        let (_, transport, _, commands) = makeBridge(playing: true)
        #expect(commands.fire(.togglePlayPause) == .success)
        #expect(commands.fire(.togglePlayPause) == .success)
        #expect(transport.calls == ["pause", "play"])
    }

    @Test func nextTrackCallsNextAndReturnsSuccess() {
        let (_, transport, _, commands) = makeBridge(playing: true)
        #expect(commands.fire(.nextTrack) == .success)
        #expect(transport.calls == ["next"])
    }

    @Test func nextTrackFailsWhenTheTransportCannotSkipAndTheControlIsHidden() {
        let center = FakeCenter()
        let commands = FakeCommands()
        let transport = FakeTransport(isPlaying: true)
        transport.supportsNext = false
        let bridge = NowPlayingBridge(center: center, commands: commands)
        commands.owner = bridge
        bridge.start(transport: transport)
        #expect(commands.supportsNext == false)
        #expect(commands.fire(.nextTrack) == .commandFailed)
        #expect(transport.calls.isEmpty)
    }

    @Test func aReleasedTransportMeansNoActionableItem() {
        let center = FakeCenter()
        let commands = FakeCommands()
        let bridge = NowPlayingBridge(center: center, commands: commands)
        commands.owner = bridge
        var transport: FakeTransport? = FakeTransport(isPlaying: true)
        bridge.start(transport: transport!)
        transport = nil
        for command in RemoteCommand.allCases {
            #expect(commands.fire(command) == .noActionableNowPlayingItem)
        }
    }

    @Test func updatePublishesTheInfoAndPlaybackState() {
        let (bridge, _, center, _) = makeBridge(playing: true)
        bridge.update(NowPlayingSnapshot(title: "Night Drive", genre: "Synthwave", elapsed: 5))
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Night Drive")
        #expect(center.playbackState == .playing)
        bridge.update(NowPlayingSnapshot(title: "Night Drive", elapsed: 9, isPlaying: false))
        #expect(center.playbackState == .paused)
        #expect(bridge.snapshot?.elapsed == 9)
    }

    @Test func stopClearsNowPlayingAndRemovesTheCommands() {
        let (bridge, transport, center, commands) = makeBridge(playing: true)
        bridge.update(NowPlayingSnapshot(title: "Night Drive"))
        bridge.stop()
        #expect(center.nowPlayingInfo == nil)
        #expect(center.playbackState == .stopped)
        #expect(bridge.snapshot == nil)
        #expect(!bridge.isActive)
        #expect(commands.uninstalls == 1)
        #expect(commands.fire(.pause) == nil)
        #expect(transport.calls.isEmpty)
    }

    @Test func aStaleHandlerDoesNothingAfterStop() {
        let (bridge, transport, _, commands) = makeBridge(playing: true)
        let handler = commands.handler
        bridge.stop()
        #expect(handler?(.pause) == .noActionableNowPlayingItem)
        #expect(transport.calls.isEmpty)
    }

    @Test func startingAgainRepointsTheCommands() {
        let (bridge, first, _, commands) = makeBridge(playing: false)
        let second = FakeTransport(isPlaying: false)
        bridge.start(transport: second)
        #expect(commands.installs == 2)
        #expect(commands.fire(.play) == .success)
        #expect(first.calls.isEmpty)
        #expect(second.calls == ["play"])
    }
}

#if os(macOS)
    import AVKit

    @MainActor @Suite struct AirPlayPickerTests {
        @Test func theRepresentableWrapsARoutePickerView() {
            let view = AirPlayPicker().makePlatformView()
            #expect(type(of: view) == AVRoutePickerView.self)
        }
    }
#endif
