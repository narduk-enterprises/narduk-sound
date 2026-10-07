#if canImport(SwiftUI)
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct ParticleFieldTests {
        static let size = CGSize(width: 160, height: 160)

        func render(_ state: SoundVisualState) -> [Double]? {
            SpectacleGolden.signature(
                of: Canvas { context, size in ParticleField.draw(into: &context, size: size, state: state) },
                size: Self.size)
        }

        @Test func aBusyFieldIsNotBlankAndIsCentered() throws {
            let signature = try #require(render(SpectacleGolden.busyState()), "this platform cannot render images")
            let g = SpectacleGolden.grid
            let corner = signature[0]
            let middle = signature[(g / 2) * g + g / 2]
            #expect(middle > 0.05, "the core should glow in the middle")
            #expect(middle > corner * 2)
        }

        @Test func theSameSequenceRendersTheSamePicture() throws {
            let a = try #require(render(SpectacleGolden.busyState()))
            let b = try #require(render(SpectacleGolden.busyState()))
            #expect(a == b)
        }

        @Test func goldenSignature() throws {
            let signature = try #require(render(SpectacleGolden.busyState()))
            #expect(SpectacleGolden.matches(signature, Self.golden))
        }

        /// 8 x 8 mean luminance of the busy state at 160 pt, recorded on macOS 27.
        static let golden: [Double] = [
            0.0, 0.001, 0.012, 0.024, 0.024, 0.012, 0.003, 0.0, 0.001, 0.024, 0.074, 0.156, 0.16, 0.075, 0.024, 0.001,
            0.012, 0.072, 0.307, 0.506, 0.484, 0.305, 0.073, 0.012, 0.025, 0.148, 0.536, 0.597, 0.597, 0.513, 0.15,
            0.023, 0.023, 0.15, 0.522, 0.598, 0.598, 0.457, 0.166, 0.023, 0.011, 0.077, 0.323, 0.512, 0.494, 0.296,
            0.075, 0.011, 0.001, 0.023, 0.07, 0.15, 0.149, 0.073, 0.023, 0.001, 0.0, 0.001, 0.012, 0.023, 0.023, 0.011,
            0.001, 0.0,
        ]
    }
#endif
