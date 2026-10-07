#if canImport(Metal)
    import Foundation
    import Metal
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What Spectrum reacts to. The shared `IntenseVisualizerTests` prove it compiles, draws, is deterministic,
    /// calms down and respects the flash cap; this file checks that the bass lights the left tubes more than the highs
    /// do, that the highs light the right tubes, and that a kick is visible.
    @MainActor @Suite struct SpectrumMetalTests {
        typealias Support = CanvasMetalSupport

        @Test(.enabled(if: Support.hasMetal, "no Metal device on this host"))
        func theBassLightsTheLeftTubesMoreThanTheHighsDo() throws {
            let quiet = try Support.render(.spectrum, bass: 0.03, highs: 0.03)
            let bassy = try Support.render(.spectrum, bass: 0.95, highs: 0.03)
            let bright = try Support.render(.spectrum, bass: 0.03, highs: 0.95)
            let left = 0...3
            let low = 3...7
            let bassGain = Support.luma(bassy, columns: left, rows: low) - Support.luma(quiet, columns: left, rows: low)
            let highGain =
                Support.luma(bright, columns: left, rows: low) - Support.luma(quiet, columns: left, rows: low)
            #expect(bassGain > 0.02)
            #expect(bassGain > highGain)
            let right = 11...15
            #expect(
                Support.luma(bright, columns: right, rows: low) > Support.luma(quiet, columns: right, rows: low) + 0.02)
        }

        @Test(.enabled(if: Support.hasMetal, "no Metal device on this host"))
        func aKickIsVisible() throws {
            let plain = try Support.render(.spectrum, bass: 0.4, highs: 0.3)
            let kicked = try Support.render(.spectrum, bass: 0.4, highs: 0.3, kicks: 4)
            #expect(plain != kicked)
            #expect(
                Support.luma(kicked, columns: 0...7, rows: 2...8) > Support.luma(plain, columns: 0...7, rows: 2...8))
        }
    }
#endif
