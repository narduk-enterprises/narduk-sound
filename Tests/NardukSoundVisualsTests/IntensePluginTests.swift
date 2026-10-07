import Foundation
import Testing

@testable import NardukSoundVisuals

@Suite struct IntensePluginHeaderTests {
    @Test func readsTitleAndFragmentFromTheHeader() throws {
        let header = try IntensePluginHeader.parse(
            source: "// title: Aurora Borealis\n// fragment: auroraFragment\nfragment float4 other(",
            fileName: "a.metal")
        #expect(header == IntensePluginHeader(title: "Aurora Borealis", fragment: "auroraFragment"))
    }

    @Test func defaultsTheTitleToTheFileAndTheFragmentToTheFirstOne() throws {
        let header = try IntensePluginHeader.parse(
            source: "// a plain comment\nfragment float4 swirl(\n    IntenseVertexOut in [[stage_in]]) {",
            fileName: "my-swirl.metal")
        #expect(header == IntensePluginHeader(title: "my-swirl", fragment: "swirl"))
    }

    @Test func aFileWithNoFragmentIsRefused() {
        #expect(throws: IntensePluginError.noFragment) {
            try IntensePluginHeader.parse(source: "// title: Nothing\nfloat x;", fileName: "n.metal")
        }
    }
}

@Suite struct IntenseLumaWatchdogTests {
    /// Feeds a luma pattern at 60 fps for `seconds` and returns the final gain and the smallest gain seen.
    static func run(seconds: Double, luma: (Int) -> Float) -> (final: Float, lowest: Float) {
        var dog = IntenseLumaWatchdog()
        var lowest: Float = 1
        for frame in 0..<Int(seconds * 60) {
            lowest = min(lowest, dog.observe(luma: luma(frame), time: 1 + Double(frame) / 60))
        }
        return (dog.gain, lowest)
    }

    @Test func dimsASyntheticStrobe() {
        // 10 Hz, 0.1 <-> 0.9: far past three jumps of 0.3 a second.
        let result = Self.run(seconds: 2) { ($0 / 3) % 2 == 0 ? 0.1 : 0.9 }
        #expect(result.final <= 0.3, "a 10 Hz strobe ended at gain \(result.final)")
        // What reaches the screen is the swing scaled by the gain, which is under a jump of 0.3.
        #expect(0.8 * result.final < IntenseLumaWatchdog.jump)
    }

    @Test func leavesThreeFlashesASecondAlone() {
        // 3 Hz: a rise every 20 frames.
        let result = Self.run(seconds: 4) { ($0 / 10) % 2 == 0 ? 0.1 : 0.9 }
        #expect(result.lowest == 1)
    }

    @Test func leavesSteadyAndGentlePicturesAlone() {
        #expect(Self.run(seconds: 3) { _ in 0.4 }.lowest == 1)
        // A fast but shallow shimmer (swing 0.2) is not a flash.
        #expect(Self.run(seconds: 3) { $0 % 2 == 0 ? 0.3 : 0.5 }.lowest == 1)
    }

    @Test func recoversOnceThePictureCalmsDown() {
        var dog = IntenseLumaWatchdog()
        for frame in 0..<120 { dog.observe(luma: (frame / 3) % 2 == 0 ? 0.1 : 0.9, time: 1 + Double(frame) / 60) }
        #expect(dog.isDimming)
        for frame in 120..<420 { dog.observe(luma: 0.4, time: 1 + Double(frame) / 60) }
        #expect(!dog.isDimming)
        #expect(dog.gain > 0.95)
    }

    @Test func aRepeatedTimeChangesNothing() {
        var dog = IntenseLumaWatchdog()
        dog.observe(luma: 0.1, time: 1)
        let before = dog
        dog.observe(luma: 0.9, time: 1)
        #expect(dog.gain == before.gain)
    }
}

#if canImport(Metal)
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis

    @MainActor @Suite struct IntensePluginTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        /// A small plugin that reads the palette, the spectrum and the rationed flash, as a real one would.
        static let fixtureSource = """
            // title: Fixture bars
            // fragment: fixtureFragment
            fragment float4 fixtureFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float band = bandAt(spectrum, in.uv.x);
                float3 color = paletteAt(u, in.uv.x + u.resTime.z * 0.1) * (0.15 + band) * (1.0 - in.uv.y);
                color += u.extra.x * u.flashColor.rgb;
                return float4(color, 1.0);
            }
            """

        static func makeFolder() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static func library(in folder: URL) throws -> IntensePluginLibrary {
            IntensePluginLibrary(directory: folder, renderer: try IntenseVisualizerTests.renderer())
        }

        static func fixtureKind() throws -> IntenseKind {
            let folder = try makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try fixtureSource.write(to: folder.appendingPathComponent("bars.metal"), atomically: true, encoding: .utf8)
            let library = try library(in: folder)
            library.reload()
            let entry = try #require(library.entries.first)
            #expect(entry.error == nil, "\(entry.error ?? "")")
            return try #require(entry.kind)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aDroppedFileCompilesAndBecomesAKind() throws {
            let kind = try Self.fixtureKind()
            #expect(kind.title == "Fixture bars" && kind.isPlugin)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aPluginRendersAPictureThatIsNeitherBlankNorWhiteAndRepeats() throws {
            let kind = try Self.fixtureKind()
            let first = try IntenseVisualizerTests.render(kind, frames: 3)
            let mean = IntenseVisualizerTests.mean(first)
            #expect(mean > 0.02 && mean < 0.95, "mean \(mean)")
            #expect(try IntenseVisualizerTests.render(kind, frames: 3) == first, "a plugin must be deterministic")
            let calm = try IntenseVisualizerTests.render(kind, frames: 3, calm: true)
            #expect(calm != first)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aPluginTakesTheGalleryPalette() throws {
            let kind = try Self.fixtureKind()
            let base = try IntenseVisualizerTests.render(kind)
            let tinted = try IntenseVisualizerTests.render(kind, look: SoundPaletteLook(preset: .ocean))
            #expect(base != tinted)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aPluginsFlashStaysUnderTheLimiter() throws {
            let kind = try Self.fixtureKind()
            let state = SoundVisualState(seed: 7)
            var limiter = IntenseFlashLimiter()
            var now = 1.0
            var frame = 0
            var levels: [Float] = []
            func step() {
                let input = SoundVisualInput(
                    frame: Script.frame(UInt64(frame + 1), level: 0.95),
                    music: Script.music(step: frame / 4, kicks: frame % 3 == 0 ? 1 : 0, snares: frame % 3 == 1 ? 1 : 0))
                state.update(input, now: now)
                now += 1.0 / 60
                frame += 1
            }
            for _ in 0..<60 { step() }
            _ = try #require(
                try IntenseVisualizerTests.renderer().renderOffscreen(
                    kind, state: state, width: 96, height: 64, frames: 240, limiter: &limiter, advance: step,
                    onFrame: { _, drive in levels.append(drive.flash) }))
            #expect(IntenseSafetyTests.worstFlashesPerSecond(levels) <= IntenseFlashLimiter.maxFlashesPerSecond)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aBrokenFileShowsItsErrorAndDoesNotTakeTheOthersDown() throws {
            let folder = try Self.makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try Self.fixtureSource.write(
                to: folder.appendingPathComponent("a-good.metal"), atomically: true, encoding: .utf8)
            try "// title: Broken\n// fragment: brokenFragment\nfragment float4 brokenFragment( { nonsense }"
                .write(to: folder.appendingPathComponent("b-broken.metal"), atomically: true, encoding: .utf8)
            try
                "// title: Misnamed\n// fragment: nothingHere\nfragment float4 realOne(IntenseVertexOut in [[stage_in]]) { return float4(1); }"
                .write(to: folder.appendingPathComponent("c-misnamed.metal"), atomically: true, encoding: .utf8)
            try "no header and no function".write(
                to: folder.appendingPathComponent("d-empty.metal"), atomically: true, encoding: .utf8)
            try "ignored".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let library = try Self.library(in: folder)
            library.reload()
            #expect(
                library.entries.map(\.id) == ["a-good.metal", "b-broken.metal", "c-misnamed.metal", "d-empty.metal"])
            #expect(library.entries[0].error == nil)
            #expect(library.entries[1].error?.isEmpty == false && library.entries[1].kind != nil)
            #expect(library.entries[2].error?.contains("nothingHere") == true)
            #expect(library.entries[3].kind == nil && library.entries[3].error?.contains("fragment") == true)
            // The good one still draws.
            let good = try #require(library.entries[0].kind)
            let pixels = try IntenseVisualizerTests.render(good)
            #expect(IntenseVisualizerTests.mean(pixels) > 0.02)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func savingAFileMakesANewKindAndTheOldPipelineIsForgotten() throws {
            let folder = try Self.makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("live.metal")
            try Self.fixtureSource.write(to: file, atomically: true, encoding: .utf8)
            let library = try Self.library(in: folder)
            library.reload()
            let first = try #require(library.entries.first?.kind)
            let revision = library.revision
            library.reload()
            #expect(library.revision == revision, "an unchanged folder is not a change")
            try Self.fixtureSource.replacingOccurrences(of: "0.15", with: "0.5")
                .write(to: file, atomically: true, encoding: .utf8)
            library.reload()
            let second = try #require(library.entries.first?.kind)
            #expect(second != first && second.id == first.id && library.revision == revision + 1)
            try "// fragment: fixtureFragment\nthis does not compile"
                .write(to: file, atomically: true, encoding: .utf8)
            library.reload()
            #expect(library.entries.first?.error != nil)
            try Self.fixtureSource.write(to: file, atomically: true, encoding: .utf8)
            library.reload()
            #expect(library.entries.first?.error == nil, "fixing the file clears its error")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSunShaderWorksUnchangedAsAPluginFile() throws {
            let folder = try Self.makeFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let text = "// title: Sun (file)\n// fragment: sunFragment\n" + SunShader.source
            try text.write(to: folder.appendingPathComponent("sun.metal"), atomically: true, encoding: .utf8)
            let library = try Self.library(in: folder)
            library.reload()
            let entry = try #require(library.entries.first)
            #expect(entry.error == nil, "\(entry.error ?? "")")
            let kind = try #require(entry.kind)
            let asPlugin = try IntenseVisualizerTests.render(kind, frames: 2)
            let builtIn = try IntenseVisualizerTests.render(.sun, frames: 2)
            #expect(asPlugin == builtIn, "the same source must draw the same picture whether built in or loaded")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aWatchedPluginDrawsThroughTheDimPassAndReportsItsLuma() throws {
            let renderer = try IntenseVisualizerTests.renderer()
            let kind = try Self.fixtureKind()
            _ = renderer.prepare(kind)
            let surface = try #require(WatchedSurface(device: renderer.device, width: 96, height: 64))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: IntenseRenderer.pixelFormat, width: 96, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
            let state = WobbleTunnelTests.busyState()
            func draw(gain: Float) throws -> (mean: Float, luma: Float) {
                var limiter = IntenseFlashLimiter()
                var uniforms = IntenseUniforms()
                let drive = IntenseDrive(state: state, limiter: &limiter)
                let buffer = try #require(renderer.queue.makeCommandBuffer())
                renderer.encodeWatched(
                    kind, buffer: buffer, target: target, state: state, drive: drive, uniforms: &uniforms,
                    motion: IntenseMotion(), surface: surface, gain: gain)
                buffer.commit()
                buffer.waitUntilCompleted()
                var pixels = [UInt8](repeating: 0, count: 96 * 64 * 4)
                target.getBytes(&pixels, bytesPerRow: 96 * 4, from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
                return (IntenseVisualizerTests.mean(pixels), surface.luma)
            }
            let full = try draw(gain: 1)
            let dimmed = try draw(gain: 0.25)
            #expect(full.mean > 0.02)
            #expect(abs(dimmed.mean - full.mean * 0.25) < 0.02, "dimmed \(dimmed.mean) vs full \(full.mean)")
            #expect(full.luma > 0.02 && abs(full.luma - dimmed.luma) < 0.01, "luma is read before the dim")
            #expect(abs(full.luma - full.mean) < 0.1)
        }
    }
#endif
