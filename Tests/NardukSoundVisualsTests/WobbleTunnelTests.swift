#if canImport(Metal)
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    @MainActor @Suite struct WobbleTunnelTests {
        /// A busy drop: loud, kicks on every beat, a snare on the backbeat. The same script drives every test here.
        static func busyState(frames: Int = 90) -> SoundVisualState {
            let state = SoundVisualState(seed: 42)
            var now = 1.0
            for i in 0..<frames {
                let kicks: UInt32 = i % 15 == 0 ? 1 : 0
                let snares: UInt32 = i % 30 == 15 ? 1 : 0
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(i + 1), level: 0.6),
                    music: Script.music(step: i / 4, kicks: kicks, snares: snares))
                state.update(input, now: now)
                now += 1.0 / 60
            }
            return state
        }

        @Test func uniformsCarryTheStateAndKeepTheShaderLayout() {
            #expect(MemoryLayout<WobbleTunnelUniforms>.size == 8 * 16)
            #expect(MemoryLayout<WobbleTunnelUniforms>.stride == 8 * 16)
            let state = Self.busyState()
            var uniforms = WobbleTunnelUniforms()
            uniforms.fill(size: CGSize(width: 320, height: 200), state: state)
            #expect(uniforms.resTime.x == 320 && uniforms.resTime.y == 200)
            #expect(uniforms.env.x == state.kick && uniforms.env.y == state.snare)
            #expect(uniforms.wobble.x == state.wobbleCutoff && uniforms.wobble.z == state.energy)
            #expect(uniforms.c0 == SIMD4(state.palette.c0, 1))
            #expect(uniforms.c2 == SIMD4(state.palette.c2, 1))
        }

        @Test func drawableSizerAppliesTheFirstSizeThenWaitsForTheResizeToSettle() {
            var sizer = WobbleTunnelDrawableSizer()
            let first = CGSize(width: 800, height: 600)
            #expect(sizer.propose(first, at: 0) == first)
            #expect(sizer.propose(first, at: 0.1) == nil)
            let bigger = CGSize(width: 900, height: 700)
            #expect(sizer.propose(bigger, at: 1.0) == nil)
            #expect(sizer.settle(at: 1.1) == nil)
            // Another size inside the window restarts the clock.
            let other = CGSize(width: 910, height: 700)
            #expect(sizer.propose(other, at: 1.2) == nil)
            #expect(sizer.settle(at: 1.4) == nil)
            #expect(sizer.settle(at: 1.5) == other)
            #expect(sizer.pending == nil)
        }

        @Test func drawableTargetIsScaledAndCapped() {
            let normal = WobbleTunnelDrawableSizer.target(
                points: CGSize(width: 400, height: 300), backingScale: 2, renderScale: 0.75)
            #expect(normal == CGSize(width: 600, height: 450))
            let huge = WobbleTunnelDrawableSizer.target(
                points: CGSize(width: 8000, height: 6000), backingScale: 2, renderScale: 0.75)
            #expect(huge.width * huge.height <= WobbleTunnelDrawableSizer.maxPixels)
            #expect(abs(huge.width / huge.height - 8.0 / 6.0) < 0.01)
        }

        /// Mean BGRA-as-RGB of each cell in a `columns` x `rows` grid, 0 ... 1.
        static func grid(_ pixels: [UInt8], width: Int, height: Int, columns: Int, rows: Int) -> [Float] {
            var out: [Float] = []
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum = SIMD3<Float>(repeating: 0)
                    var n: Float = 0
                    for y in (row * height / rows)..<((row + 1) * height / rows) {
                        for x in (column * width / columns)..<((column + 1) * width / columns) {
                            let i = (y * width + x) * 4
                            sum += SIMD3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])) / 255
                            n += 1
                        }
                    }
                    let mean = sum / n
                    out += [mean.x, mean.y, mean.z]
                }
            }
            return out
        }

        static let size = (width: 96, height: 64)

        /// False on a host with no Metal device (a headless runner, a VM without a GPU): the GPU tests skip there
        /// with this reason instead of failing. On a host that has a device, a shader that does not compile fails.
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> WobbleTunnelRenderer {
            try #require(
                WobbleTunnelRenderer(device: MTLCreateSystemDefaultDevice()),
                "the tunnel shader did not compile or its pipeline could not be built")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aBusyDropRendersAPictureThatIsNotBlankAndNotWhite() throws {
            let renderer = try Self.renderer()
            let pixels = try #require(
                renderer.renderOffscreen(state: Self.busyState(), width: Self.size.width, height: Self.size.height))
            let cells = Self.grid(pixels, width: Self.size.width, height: Self.size.height, columns: 4, rows: 3)
            let mean = cells.reduce(0, +) / Float(cells.count)
            #expect(mean > 0.02, "the tunnel drew nothing (mean \(mean))")
            #expect(mean < 0.9, "the tunnel is a white flash (mean \(mean))")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func silenceIsDarkerThanADrop() throws {
            let renderer = try Self.renderer()
            let quiet = SoundVisualState(seed: 42)
            var now = 1.0
            for i in 0..<30 {
                quiet.update(SoundVisualInput(frame: Script.frame(UInt64(i + 1), level: 0, rmsDB: -120)), now: now)
                now += 1.0 / 60
            }
            let quietPixels = try #require(
                renderer.renderOffscreen(state: quiet, width: Self.size.width, height: Self.size.height))
            let busyPixels = try #require(
                renderer.renderOffscreen(state: Self.busyState(), width: Self.size.width, height: Self.size.height))
            func mean(_ pixels: [UInt8]) -> Float {
                Self.grid(pixels, width: Self.size.width, height: Self.size.height, columns: 1, rows: 1).reduce(0, +)
            }
            #expect(mean(quietPixels) < mean(busyPixels))
        }

        /// The golden image: the busy script rendered at 96 x 64 and reduced to a 4 x 3 grid of mean colors, compared
        /// with a tolerance because two GPUs round fast-math differently. A shader or mapping change moves it.
        @Test(.enabled(if: hasMetal, "no Metal device on this host")) func goldenGridForTheBusyScript() throws {
            let renderer = try Self.renderer()
            let pixels = try #require(
                renderer.renderOffscreen(state: Self.busyState(), width: Self.size.width, height: Self.size.height))
            let cells = Self.grid(pixels, width: Self.size.width, height: Self.size.height, columns: 4, rows: 3)
            #expect(cells.count == Self.golden.count)
            for (actual, expected) in zip(cells, Self.golden) {
                #expect(abs(actual - expected) < 0.06, "cell \(actual) vs golden \(expected)")
            }
        }

        /// Row-major cells, each r, g, b. Taken from an Apple-silicon run on 2026-10-06.
        static let golden: [Float] = [
            0.285, 0.352, 0.168, 0.450, 0.517, 0.265, 0.422, 0.403, 0.273,
            0.227, 0.232, 0.137, 0.323, 0.376, 0.169, 0.659, 0.520, 0.576,
            0.562, 0.349, 0.546, 0.297, 0.217, 0.210, 0.268, 0.290, 0.157,
            0.417, 0.254, 0.323, 0.322, 0.107, 0.272, 0.186, 0.094, 0.145,
        ]
    }

    #if canImport(Darwin)
        extension SoundVisualStateAllocationTests {
            /// The tunnel's per-frame CPU work is filling the uniforms and handing the state's buffers to the encoder;
            /// the filling must not allocate. (Release build only, like the state's own test.)
            @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
            @MainActor func fillingTheTunnelUniformsNeverAllocates() throws {
                let state = WobbleTunnelTests.busyState()
                var uniforms = WobbleTunnelUniforms()
                uniforms.fill(size: CGSize(width: 640, height: 400), state: state)
                let count = try Self.countAllocations {
                    for i in 0..<600 {
                        uniforms.fill(size: CGSize(width: 640 + CGFloat(i % 7), height: 400), state: state)
                    }
                }
                #expect(count == 0, "fill allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
            }
        }
    #endif
#endif
