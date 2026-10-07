#if canImport(SwiftUI)
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct BeatKaleidoscopeTests {
        static let size = CGSize(width: 160, height: 160)

        func render(_ state: SoundVisualState) -> [Double]? {
            SpectacleGolden.signature(
                of: Canvas { context, size in BeatKaleidoscope.draw(into: &context, size: size, state: state) },
                size: Self.size)
        }

        @Test func aBusyKaleidoscopeIsNotBlank() throws {
            let signature = try #require(render(SpectacleGolden.busyState()), "this platform cannot render images")
            #expect(signature.reduce(0, +) / Double(signature.count) > 0.01)
        }

        @Test func theSameSequenceRendersTheSamePicture() throws {
            let a = try #require(render(SpectacleGolden.busyState()))
            let b = try #require(render(SpectacleGolden.busyState()))
            #expect(a == b)
        }

        @Test func aDropFoldsMoreWedges() {
            #expect(BeatKaleidoscope.foldCount(SpectacleGolden.busyState()) == 8)
            #expect(BeatKaleidoscope.foldCount(SoundVisualState()) == 6)
        }

        @Test func goldenSignature() throws {
            let signature = try #require(render(SpectacleGolden.busyState()))
            #expect(SpectacleGolden.matches(signature, Self.golden, tolerance: 0.015))
        }

        /// 8 x 8 mean luminance of the busy state at 160 pt, recorded on macOS 27. The picture is dim, so the tolerance is tight.
        static let golden: [Double] = [
            0.0, 0.024, 0.047, 0.049, 0.049, 0.047, 0.024, 0.0, 0.024, 0.045, 0.041, 0.056, 0.068, 0.041, 0.045, 0.024,
            0.047, 0.041, 0.06, 0.085, 0.037, 0.063, 0.041, 0.047, 0.049, 0.064, 0.034, 0.071, 0.077, 0.097, 0.056,
            0.049, 0.049, 0.056, 0.068, 0.061, 0.075, 0.04, 0.07, 0.049, 0.047, 0.041, 0.055, 0.036, 0.09, 0.065, 0.041,
            0.047, 0.024, 0.045, 0.041, 0.066, 0.056, 0.041, 0.045, 0.024, 0.0, 0.024, 0.047, 0.049, 0.049, 0.047,
            0.024, 0.0,
        ]
    }
#endif
