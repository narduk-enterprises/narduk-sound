import Testing

@testable import NardukMusicEngine

@Suite struct SessionPolicyTests {
    @Test func aRunningEnginePausesWhenAnInterruptionBegins() {
        #expect(
            InterruptionResponse.response(
                began: true, shouldResume: false, wasRunning: true, pausedByInterruption: false)
                == .pause)
    }

    @Test func aStoppedEngineIgnoresAnInterruption() {
        #expect(
            InterruptionResponse.response(
                began: true, shouldResume: false, wasRunning: false, pausedByInterruption: false)
                == .none)
    }

    @Test func itResumesOnlyWhenItPausedAndTheSystemSaysTo() {
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: true, wasRunning: false, pausedByInterruption: true)
                == .resume)
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: false, wasRunning: false, pausedByInterruption: true)
                == .none)
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: true, wasRunning: false, pausedByInterruption: false)
                == .none)
    }

    @MainActor @Test func lookaheadCoversAMainThreadHiccupOffMacOS() {
        #if os(macOS)
            #expect(DropEngine.lookaheadSeconds == 0.1)
        #else
            #expect(DropEngine.lookaheadSeconds >= 0.25)
        #endif
    }
}

@Suite struct ReroutePolicyTests {
    @Test func unpluggingTheOutputPausesARunningSong() {
        #expect(
            RouteChangeResponse.response(reason: .oldDeviceUnavailable, isRunning: true, isPaused: false) == .pause)
    }

    @Test func aStoppedOrAlreadyPausedSongHasNothingToPause() {
        #expect(
            RouteChangeResponse.response(reason: .oldDeviceUnavailable, isRunning: false, isPaused: false)
                == .keepPlaying)
        #expect(
            RouteChangeResponse.response(reason: .oldDeviceUnavailable, isRunning: true, isPaused: true)
                == .keepPlaying)
    }

    @Test func everyOtherRouteChangeKeepsPlaying() {
        let others: [RouteChangeReason] = [
            .unknown, .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory,
            .routeConfigurationChange,
        ]
        for reason in others {
            #expect(
                RouteChangeResponse.response(reason: reason, isRunning: true, isPaused: false) == .keepPlaying,
                "\(reason) should keep playing")
        }
    }

    /// The raw values are AVAudioSession's stable API; a nil or unknown value is `.unknown`, which keeps playing.
    @Test func routeChangeReasonsDecodeFromTheSessionsRawValues() {
        #expect(RouteChangeReason(rawValue: 1) == .newDeviceAvailable)
        #expect(RouteChangeReason(rawValue: 2) == .oldDeviceUnavailable)
        #expect(RouteChangeReason(rawValue: 3) == .categoryChange)
        #expect(RouteChangeReason(rawValue: 4) == .override)
        #expect(RouteChangeReason(rawValue: 6) == .wakeFromSleep)
        #expect(RouteChangeReason(rawValue: 7) == .noSuitableRouteForCategory)
        #expect(RouteChangeReason(rawValue: 8) == .routeConfigurationChange)
        #expect(RouteChangeReason(rawValue: 0) == .unknown)
        #expect(RouteChangeReason(rawValue: 5) == .unknown)
        #expect(RouteChangeReason(rawValue: nil) == .unknown)
    }

    /// Config change and media-services reset share this decision: rebuild around the same song.
    @Test func aRunningSongIsRebuiltAndPlaysOn() {
        #expect(GraphRebuildResponse.response(isRunning: true, isPaused: false) == .rebuildAndPlay)
    }

    @Test func aPausedSongIsRebuiltButStaysHeld() {
        #expect(GraphRebuildResponse.response(isRunning: true, isPaused: true) == .rebuildHeld)
    }

    @Test func aStoppedEngineHasNothingToRebuild() {
        #expect(GraphRebuildResponse.response(isRunning: false, isPaused: false) == .none)
    }

    /// The whole interruption path with and without the system's resume hint, as the engine feeds it.
    @Test func anInterruptionResumesOnlyWithTheHint() {
        let began = InterruptionResponse.response(
            began: true, shouldResume: false, wasRunning: true, pausedByInterruption: false)
        #expect(began == .pause)
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: true, wasRunning: true, pausedByInterruption: true) == .resume)
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: false, wasRunning: true, pausedByInterruption: true) == .none)
    }

    /// A song the listener paused is not "running" to the interruption policy, so its end does not start it.
    @Test func aSongPausedByTheListenerIsLeftAloneByAnInterruption() {
        #expect(
            InterruptionResponse.response(
                began: true, shouldResume: false, wasRunning: false, pausedByInterruption: false) == .none)
        #expect(
            InterruptionResponse.response(
                began: false, shouldResume: true, wasRunning: false, pausedByInterruption: false) == .none)
    }
}
