#if canImport(Darwin)
    import Foundation
    import Testing

    @testable import NardukSoundVisuals

    /// The intense visualizers' per-frame CPU path (the drive, the flash limiter and the uniform fill) must not
    /// allocate: it runs at 60 Hz on the main thread. The GPU encode reuses the uniforms, the state's own buffers and a
    /// pre-built fluid surface, as the tunnel does. Needs an optimized build: run it under `swift test -c release`.
    @MainActor @Suite(.serialized) struct IntenseAllocationTests {
        @Test(.enabled(if: SoundVisualStateAllocationTests.optimized, "allocation counts need swift test -c release"))
        func theDriveAndUniformPathNeverAllocates() throws {
            let state = WobbleTunnelTests.busyState()
            var limiter = IntenseFlashLimiter()
            var uniforms = IntenseUniforms()
            var sink: Float = 0
            let count = try SoundVisualStateAllocationTests.countAllocations {
                for frame in 0..<2_000 {
                    let drive = IntenseDrive(
                        flashDemand: frame % 7 == 0 ? 1 : 0, glitchDemand: state.glitch, tint: state.palette.c2,
                        calm: frame % 500 > 400, now: Double(frame) / 60, limiter: &limiter)
                    uniforms.fill(size: CGSize(width: 640, height: 480), state: state, drive: drive)
                    sink += drive.flash + uniforms.extra.x + uniforms.extra.w + uniforms.flashColor.x
                    sink += IntenseDrive(state: state, limiter: &limiter).flash
                }
            }
            #expect(count == 0, "the intense draw path allocated \(count) times")
            #expect(sink.isFinite)
        }
    }
#endif
