import Foundation
import NardukMusicCore
import Testing

@testable import NardukSoundVisuals

/// The dive's and flyover's motion, which needs no GPU. The shared flash cap, calm and picture tests live in
/// `IntenseVisualizerTests`, which runs over every `IntenseKind`.
@Suite struct IntenseMotionTests {
    static func run(
        _ kind: IntenseKind, seconds: Double, kick: Float = 0, energy: Float = 0, drop: Float = 0,
        intensity: Float = 1
    ) -> IntenseMotion {
        var motion = IntenseMotion()
        for i in 0...Int(seconds * 60) {
            motion.advance(
                kind, time: 1 + Double(i) / 60, kick: kick, energy: energy, dropAmount: drop, section: .drop,
                intensity: intensity)
        }
        return motion
    }

    @Test func aRepeatedFrameMovesNothing() {
        var motion = IntenseMotion()
        for time in [1.0, 1.016] {
            motion.advance(
                .fractalDive, time: time, kick: 1, energy: 0.8, dropAmount: 0, section: .drop, intensity: 1)
        }
        let once = motion
        motion.advance(.fractalDive, time: 1.016, kick: 1, energy: 0.8, dropAmount: 0, section: .drop, intensity: 1)
        #expect(motion == once)
    }

    @Test func theBassPushesTheZoom() {
        #expect(Self.run(.fractalDive, seconds: 3, kick: 1).depth > Self.run(.fractalDive, seconds: 3, kick: 0).depth)
    }

    @Test func theDiveStaysInsideTheFloatsPrecision() {
        for seconds in stride(from: 0.0, to: 120, by: 7) {
            let depth = Self.run(.fractalDive, seconds: seconds, kick: 0.6, energy: 0.5).depth
            #expect(depth >= 0 && depth <= IntenseMotion.maxDepth)
        }
    }

    @Test func eachDiveEndsAtTheSurfaceAndPicksTheNextTarget() {
        var motion = IntenseMotion()
        var seen = Set<[Float]>()
        for i in 0..<(60 * 240) {
            motion.advance(
                .fractalDive, time: 1 + Double(i) / 60, kick: 1, energy: 1, dropAmount: 0, section: .drop, intensity: 1)
            seen.insert([motion.target.x, motion.target.y])
        }
        #expect(seen.count == IntenseMotion.targets.count)
        // The target only changes at the surface, so the swap is not seen.
        #expect(IntenseMotion(phase: 2 * .pi).depth < 0.001)
        #expect(IntenseMotion(phase: 2 * .pi).target != IntenseMotion(phase: 2 * .pi - 0.01).target)
        #expect(IntenseMotion(phase: 2 * .pi - 0.01).depth < 0.01)
    }

    @Test func sectionChangesTurnThePicture() {
        var motion = IntenseMotion()
        for i in 0..<240 {
            motion.advance(
                .fractalDive, time: 1 + Double(i) / 60, kick: 0, energy: 0, dropAmount: 0,
                section: i < 120 ? .intro : .drop, intensity: 1)
        }
        #expect(motion.morph > 0.3)
    }

    @Test func theDropLiftsTheFlyoverOffAndCalmLiftsLess() {
        let loud = Self.run(.synthwaveFlyover, seconds: 5, drop: 1)
        let calm = Self.run(.synthwaveFlyover, seconds: 5, drop: 1, intensity: IntenseDrive.calmIntensity)
        #expect(loud.lift > 0.9)
        #expect(calm.lift < loud.lift * 0.5)
    }

    @Test func calmSlowsAndFlattensTheFlyover() {
        let loud = Self.run(.synthwaveFlyover, seconds: 5, energy: 0.7)
        let calm = Self.run(.synthwaveFlyover, seconds: 5, energy: 0.7, intensity: IntenseDrive.calmIntensity)
        #expect(calm.travel < loud.travel * 0.6)
        #expect(calm.packed.1.z < loud.packed.1.z)
    }
}

#if canImport(Metal)
    import Metal

    @MainActor @Suite struct IntenseMotionCaptureTests {
        /// Writes stills of the dive and flyover over a long script as PPMs into `INTENSE_B_CAPTURE_DIR` when it is
        /// set: the lane's offline evidence, never run in CI.
        @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
        func captureStills() throws {
            guard let dir = ProcessInfo.processInfo.environment["INTENSE_B_CAPTURE_DIR"] else { return }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let (width, height) = (480, 270)
            let renderer = try #require(IntenseRenderer(device: MTLCreateSystemDefaultDevice()))
            for kind in [IntenseKind.fractalDive, .synthwaveFlyover] {
                let state = SoundVisualState(seed: 7)
                var limiter = IntenseFlashLimiter()
                var now = 1.0
                var frame = 0
                func step() {
                    let section: SongSection = (frame / 600) % 2 == 0 ? .build : .drop
                    let input = SoundVisualInput(
                        frame: Script.frame(UInt64(frame + 1), level: 0.7),
                        music: Script.music(
                            step: frame / 4, kicks: frame % 15 == 0 ? 1 : 0, snares: frame % 30 == 15 ? 1 : 0,
                            section: section))
                    state.update(input, now: now)
                    now += 1.0 / 60
                    frame += 1
                }
                for shot in 0..<12 {
                    let pixels = try #require(
                        renderer.renderOffscreen(
                            kind, state: state, width: width, height: height, frames: shot == 0 ? 60 : 240,
                            limiter: &limiter, advance: step))
                    var ppm = Data("P6\n\(width) \(height)\n255\n".utf8)
                    for i in stride(from: 0, to: pixels.count, by: 4) {
                        ppm.append(contentsOf: [pixels[i + 2], pixels[i + 1], pixels[i]])
                    }
                    try ppm.write(to: URL(fileURLWithPath: "\(dir)/\(kind.rawValue)-\(shot).ppm"))
                }
            }
        }
    }
#endif

#if canImport(Darwin)
    extension SoundVisualStateAllocationTests {
        /// The dive's and flyover's per-frame CPU work is advancing the motion and packing it for the shader; neither
        /// may allocate. (Release build only, like the state's own test.)
        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        @MainActor func advancingTheIntenseMotionNeverAllocates() throws {
            let state = WobbleTunnelTests.busyState()
            var motions = [IntenseMotion(), IntenseMotion()]
            let kinds: [IntenseKind] = [.fractalDive, .synthwaveFlyover]
            var sink: Float = 0
            for index in 0..<2 {  // the first call builds the static target list
                motions[index].advance(kinds[index], state: state, intensity: 1)
                sink += motions[index].packed.0.x
            }
            let count = try Self.countAllocations {
                for i in 0..<600 {
                    for index in 0..<2 {
                        motions[index].advance(kinds[index], state: state, intensity: i % 2 == 0 ? 1 : 0.4)
                        sink += motions[index].packed.0.x + motions[index].packed.1.x
                    }
                }
            }
            #expect(count == 0, "the intense motion allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
            #expect(sink.isFinite)
        }
    }
#endif
