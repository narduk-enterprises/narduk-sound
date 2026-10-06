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
