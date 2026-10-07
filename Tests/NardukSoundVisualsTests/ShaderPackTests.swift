#if canImport(Metal)
    import Metal
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct ShaderPackTests {
        static let size = (width: 96, height: 64)

        /// False on a host with no Metal device: the GPU tests skip there. On a host with a device, a shader that
        /// does not compile fails.
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer {
            try #require(
                ShaderPackRenderer(device: MTLCreateSystemDefaultDevice()),
                "a pack shader did not compile or its pipeline could not be built")
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            WobbleTunnelTests.grid(pixels, width: size.width, height: size.height, columns: 1, rows: 1).reduce(0, +) / 3
        }

        static func render(_ kind: ShaderPackKind, frames: Int = 1, calm: Bool = false) throws -> [UInt8] {
            let state = WobbleTunnelTests.busyState()
            return try #require(
                try renderer().renderOffscreen(
                    kind, state: state, width: size.width, height: size.height, frames: frames, calm: calm))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: ShaderPackKind.allCases)
        func everyShaderDrawsAPictureThatIsNeitherBlankNorWhite(kind: ShaderPackKind) throws {
            let mean = Self.mean(try Self.render(kind, frames: kind == .feedback ? 12 : 1))
            #expect(mean > 0.01, "\(kind) drew nothing (mean \(mean))")
            #expect(mean < 0.85, "\(kind) is a white flash (mean \(mean))")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: ShaderPackKind.allCases)
        func theSameStateRendersTheSamePicture(kind: ShaderPackKind) throws {
            #expect(try Self.render(kind, frames: 3) == Self.render(kind, frames: 3))
        }

        /// The feedback shader remembers: after more frames the trails have built up, so the picture is brighter
        /// and different from the first frame.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func feedbackBuildsTrailsOverFrames() throws {
            let first = try Self.render(.feedback, frames: 1)
            let later = try Self.render(.feedback, frames: 24)
            #expect(first != later)
            #expect(Self.mean(later) > Self.mean(first))
        }

        /// Golden: each shader's picture reduced to a 4 x 3 grid of mean luminance (r+g+b)/3, with a tolerance because
        /// two GPUs round fast-math differently. Feedback is 12 frames in. Taken from an Apple-silicon run.
        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: ShaderPackKind.allCases)
        func goldenGrid(kind: ShaderPackKind) throws {
            let pixels = try Self.render(kind, frames: kind == .feedback ? 12 : 1)
            let cells = WobbleTunnelTests.grid(
                pixels, width: Self.size.width, height: Self.size.height, columns: 4, rows: 3)
            var luminance: [Float] = []
            for i in stride(from: 0, to: cells.count, by: 3) {
                luminance.append((cells[i] + cells[i + 1] + cells[i + 2]) / 3)
            }
            let golden = try #require(Self.golden[kind])
            #expect(luminance.count == golden.count)
            for (actual, expected) in zip(luminance, golden) {
                #expect(abs(actual - expected) < 0.03, "\(kind): cell \(actual) vs golden \(expected)")
            }
        }

        static let golden: [ShaderPackKind: [Float]] = [
            .plasma: [0.352, 0.362, 0.351, 0.367, 0.359, 0.352, 0.354, 0.36, 0.37, 0.369, 0.366, 0.36],
            .warpGrid: [0.032, 0.146, 0.146, 0.032, 0.128, 0.234, 0.244, 0.133, 0.02, 0.097, 0.047, 0.015],
            .starfield: [0.035, 0.033, 0.037, 0.01, 0.021, 0.069, 0.076, 0.024, 0.021, 0.029, 0.034, 0.012],
            .feedback: [0.0, 0.029, 0.066, 0.0, 0.0, 0.12, 0.179, 0.0, 0.0, 0.046, 0.046, 0.0],
            .bassBlobs: [
                0.018, 0.044, 0.012, 0.010, 0.082, 0.295, 0.223, 0.067, 0.101, 0.120, 0.136, 0.102,
            ],
            .aurora: [0.398, 0.411, 0.411, 0.402, 0.402, 0.406, 0.411, 0.397, 0.129, 0.102, 0.093, 0.102],
            .auroraWaves: [0.274, 0.3, 0.33, 0.328, 0.557, 0.573, 0.599, 0.594, 0.349, 0.346, 0.333, 0.35],
            .meshWave: [
                0.183, 0.101, 0.000, 0.117, 0.131, 0.696, 0.009, 0.674, 0.000, 0.423, 0.375, 0.550,
            ],
            .solarFlare: [0.135, 0.176, 0.176, 0.125, 0.150, 0.326, 0.308, 0.147, 0.126, 0.176, 0.179, 0.104],
            .oceanWaves: [0.089, 0.210, 0.499, 0.409, 0.318, 0.435, 0.499, 0.437, 0.391, 0.415, 0.471, 0.435],
            .fireworks: [
                0.207, 0.126, 0.025, 0.042, 0.351, 0.532, 0.438, 0.438, 0.120, 0.185, 0.237, 0.130,
            ],
        ]
    }
#endif
