import Testing

@testable import NardukSoundVisuals

/// The photosensitivity limits of the intense visualizers (narduk-libs#1615): a children's app must never flash the
/// screen more than three times a second, never flash a hard red, and flash nothing in calm.
@Suite struct IntenseSafetyTests {
    /// Runs `demand(frame)` through a limiter at 60 fps for `seconds` and returns each frame's output.
    static func run(seconds: Double, calm: Bool = false, demand: (Int) -> Float) -> [Float] {
        var limiter = IntenseFlashLimiter()
        var out: [Float] = []
        for frame in 0..<Int(seconds * 60) {
            out.append(limiter.limit(demand(frame), now: Double(frame) / 60, calm: calm))
        }
        return out
    }

    /// The most flashes that start in any rolling one-second window of `levels` (60 fps): a flash starts when the
    /// level rises from nothing.
    static func worstFlashesPerSecond(_ levels: [Float]) -> Int {
        var starts: [Int] = []
        for index in levels.indices where levels[index] > 0 && (index == 0 || levels[index - 1] == 0) {
            starts.append(index)
        }
        var worst = 0
        for (i, start) in starts.enumerated() {
            let inWindow = starts[i...].prefix { $0 < start + 60 }.count
            worst = max(worst, inWindow)
        }
        return worst
    }

    @Test func aTwentyHertzStrobeIsHeldToThreeFlashesASecond() {
        let out = Self.run(seconds: 10) { $0 % 3 == 0 ? 1 : 0 }
        #expect(out.contains { $0 > 0 }, "the limiter refused every flash")
        #expect(Self.worstFlashesPerSecond(out) <= IntenseFlashLimiter.maxFlashesPerSecond)
    }

    @Test(arguments: [2, 4, 5, 7, 9, 11])
    func anyStrobePeriodStaysWithinTheCap(period: Int) {
        let out = Self.run(seconds: 12) { $0 % period < max(period / 2, 1) ? 0.9 : 0 }
        #expect(Self.worstFlashesPerSecond(out) <= IntenseFlashLimiter.maxFlashesPerSecond)
    }

    @Test func aPseudoRandomStrobeStaysWithinTheCap() {
        var seed: UInt32 = 12345
        let out = Self.run(seconds: 30) { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 24) / 255
        }
        #expect(Self.worstFlashesPerSecond(out) <= IntenseFlashLimiter.maxFlashesPerSecond)
    }

    @Test func aSlowBeatStillFlashesEveryBeat() {
        // Two flashes a second is under the cap, so none is refused.
        let out = Self.run(seconds: 4) { $0 % 30 < 6 ? 1 : 0 }
        #expect(Self.worstFlashesPerSecond(out) == 2)
    }

    @Test func aFlashIsNeverBrighterThanTheCap() {
        let out = Self.run(seconds: 3) { _ in 1 }
        #expect(out.max() == IntenseFlashLimiter.maxLevel)
    }

    @Test func calmDrawsNoFlashAtAll() {
        let out = Self.run(seconds: 5, calm: true) { _ in 1 }
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func aHardRedFlashIsTurnedIntoAWarmWhite() {
        let red = IntenseFlashLimiter.safeFlashColor(SIMD3(1, 0, 0))
        #expect(red.x / (red.x + red.y + red.z) <= 0.61, "still a saturated red: \(red)")
        let cyan = SIMD3<Float>(0.1, 0.9, 0.95)
        #expect(IntenseFlashLimiter.safeFlashColor(cyan) == cyan)
    }

    @Test func theDriveIsCalmWhenAskedAndAlwaysRedSafe() {
        var limiter = IntenseFlashLimiter()
        let calm = IntenseDrive(
            flashDemand: 1, glitchDemand: 1, tint: SIMD3(1, 0, 0), calm: true, now: 1, limiter: &limiter)
        #expect(calm.flash == 0 && calm.glitch == 0 && calm.intensity == IntenseDrive.calmIntensity)
        var loud = IntenseFlashLimiter()
        let drive = IntenseDrive(
            flashDemand: 1, glitchDemand: 2, tint: SIMD3(1, 0, 0), calm: false, now: 1, limiter: &loud)
        #expect(drive.flash == IntenseFlashLimiter.maxLevel && drive.glitch == 1 && drive.intensity == 1)
        #expect(drive.flashColor.x / (drive.flashColor.x + drive.flashColor.y + drive.flashColor.z) <= 0.61)
    }
}
