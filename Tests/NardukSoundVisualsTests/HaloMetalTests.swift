#if canImport(Metal)
    import Foundation
    import Metal
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// What Halo (Metal) reacts to. The shared `IntenseVisualizerTests` prove it compiles, draws, is deterministic,
    /// calms down and respects the flash cap; this file checks that the bass swells the core more than the highs do,
    /// that the highs still change the rim, and that a kick is visible.
    @MainActor @Suite struct HaloMetalTests {
        typealias Support = CanvasMetalSupport
        static let core = (columns: 7...8, rows: 4...4)

        @Test(.enabled(if: Support.hasMetal, "no Metal device on this host"))
        func theBassSwellsTheCoreMoreThanTheHighsDo() throws {
            let quiet = try Support.render(.haloMetal, bass: 0.03, highs: 0.03)
            let bassy = try Support.render(.haloMetal, bass: 0.95, highs: 0.03)
            let bright = try Support.render(.haloMetal, bass: 0.03, highs: 0.95)
            func core(_ pixels: [UInt8]) -> Float {
                Support.luma(pixels, columns: Self.core.columns, rows: Self.core.rows)
            }
            #expect(core(bassy) > core(quiet) + 0.02)
            #expect(core(bassy) - core(quiet) > core(bright) - core(quiet))
            #expect(bright != quiet)
        }

        @Test(.enabled(if: Support.hasMetal, "no Metal device on this host"))
        func aKickIsVisible() throws {
            let plain = try Support.render(.haloMetal, bass: 0.4, highs: 0.3)
            let kicked = try Support.render(.haloMetal, bass: 0.4, highs: 0.3, kicks: 4)
            #expect(plain != kicked)
            #expect(
                Support.luma(kicked, columns: Self.core.columns, rows: Self.core.rows)
                    > Support.luma(plain, columns: Self.core.columns, rows: Self.core.rows))
        }
    }
#endif
