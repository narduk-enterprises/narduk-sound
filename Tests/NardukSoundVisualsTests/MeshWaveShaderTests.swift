#if canImport(Metal)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing
    import UniformTypeIdentifiers

    @testable import NardukSoundVisuals

    @MainActor @Suite struct MeshWaveShaderTests {
        static let size = (width: 192, height: 108)

        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static func renderer() throws -> ShaderPackRenderer {
            let device = try #require(MTLCreateSystemDefaultDevice(), "no Metal device on this host")
            if let renderer = ShaderPackRenderer(device: device) { return renderer }
            let options = MTLCompileOptions()
            options.mathMode = .fast
            do { _ = try device.makeLibrary(source: ShaderPackSource.source, options: options) } catch {
                Issue.record("Metal compile failed: \(error)")
            }
            return try #require(
                ShaderPackRenderer(device: device), "a pack shader did not compile or its pipeline could not be built")
        }

        static func frame(_ sequence: UInt64, bass: Float, mids: Float, highs: Float) -> SoundFrame {
            var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
            for index in 0..<10 { spectrum[index] = bass }
            for index in 10..<36 { spectrum[index] = mids }
            for index in 36..<spectrum.count { spectrum[index] = highs }
            return SoundFrame(
                sequence: sequence, time: Double(sequence) / 60, spectrum: spectrum, peakDB: -6, rmsDB: -12)
        }

        /// A settled picture. `kick` fires on the last frame, after the spectrum-onset kick has decayed.
        static func state(bass: Float, mids: Float, highs: Float, kick: Bool, frames: Int = 48) -> SoundVisualState {
            let state = SoundVisualState(seed: 7)
            state.lookEaseDuration = 0.001
            state.look = SoundPaletteLook(
                colors: SoundPalette(
                    c0: SIMD3(0.08, 0.48, 1), c1: SIMD3(0.50, 0.20, 0.98), c2: SIMD3(0.72, 0.90, 1)))
            var now = 0.25
            for index in 0..<frames {
                let fire = kick && index == frames - 1
                let input = SoundVisualInput(
                    frame: frame(UInt64(index + 1), bass: bass, mids: mids, highs: highs),
                    music: Script.music(step: index / 4, kicks: fire ? 1 : 0, section: .intro))
                state.update(input, now: now)
                now += 1.0 / 60
            }
            return state
        }

        static func render(_ state: SoundVisualState, calm: Bool, width: Int, height: Int) throws -> [UInt8] {
            try #require(
                try renderer().renderOffscreen(.meshWave, state: state, width: width, height: height, calm: calm))
        }

        static func mean(_ pixels: [UInt8]) -> Float {
            var sum: Float = 0
            var count: Float = 0
            var index = 0
            while index + 2 < pixels.count {
                sum += Float(pixels[index]) + Float(pixels[index + 1]) + Float(pixels[index + 2])
                count += 3
                index += 4
            }
            return sum / count / 255
        }

        static func delta(_ a: [UInt8], _ b: [UInt8]) -> Float {
            var sum: Float = 0
            var count: Float = 0
            var index = 0
            while index + 2 < a.count && index + 2 < b.count {
                sum += abs(Float(a[index]) - Float(b[index]))
                sum += abs(Float(a[index + 1]) - Float(b[index + 1]))
                sum += abs(Float(a[index + 2]) - Float(b[index + 2]))
                count += 3
                index += 4
            }
            return sum / count / 255
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func aMeshWaveIsNeitherBlankNorWhite() throws {
            let quietState = Self.state(bass: 0.12, mids: 0.08, highs: 0.04, kick: false)
            let loudState = Self.state(bass: 0.95, mids: 0.2, highs: 0.1, kick: false)
            let quiet = try Self.render(
                quietState, calm: false, width: Self.size.width, height: Self.size.height)
            let loud = try Self.render(
                loudState, calm: false, width: Self.size.width, height: Self.size.height)
            for (name, pixels) in [("quiet", quiet), ("loud", loud)] {
                let mean = Self.mean(pixels)
                #expect(mean > 0.01, "\(name) drew nothing (mean \(mean))")
                #expect(mean < 0.85, "\(name) is a white flash (mean \(mean))")
            }
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func bassChangesThePictureMoreThanHighs() throws {
            let quietState = Self.state(bass: 0.08, mids: 0.1, highs: 0.05, kick: false)
            let bassState = Self.state(bass: 0.95, mids: 0.1, highs: 0.05, kick: false)
            let highsState = Self.state(bass: 0.08, mids: 0.1, highs: 0.95, kick: false)
            let quiet = try Self.render(
                quietState, calm: false, width: Self.size.width, height: Self.size.height)
            let bass = try Self.render(
                bassState, calm: false, width: Self.size.width, height: Self.size.height)
            let highs = try Self.render(
                highsState, calm: false, width: Self.size.width, height: Self.size.height)
            let bassDelta = Self.delta(quiet, bass)
            let highsDelta = Self.delta(quiet, highs)
            #expect(bassDelta > 0.01, "bass did not move the mesh (delta \(bassDelta))")
            #expect(bassDelta > highsDelta, "bass delta \(bassDelta) should exceed highs delta \(highsDelta)")
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func theSameStateRendersTheSamePicture() throws {
            let state = Self.state(bass: 0.55, mids: 0.35, highs: 0.2, kick: true)
            let first = try Self.render(state, calm: false, width: Self.size.width, height: Self.size.height)
            let second = try Self.render(state, calm: false, width: Self.size.width, height: Self.size.height)
            #expect(first == second)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func calmSlowsThePictureAndRemovesTheKickRipple() throws {
            let resting = Self.state(bass: 0.45, mids: 0.55, highs: 0.15, kick: false)
            let kicked = Self.state(bass: 0.45, mids: 0.55, highs: 0.15, kick: true)
            let moving = try Self.render(kicked, calm: false, width: Self.size.width, height: Self.size.height)
            let calm = try Self.render(kicked, calm: true, width: Self.size.width, height: Self.size.height)
            let calmMean = Self.mean(calm)
            #expect(calmMean > 0.01, "calm drew nothing (mean \(calmMean))")
            #expect(calmMean < 0.85, "calm is a white flash (mean \(calmMean))")
            #expect(Self.delta(moving, calm) > 0.004, "calm did not change the motion")
            let liveKick = Self.delta(
                moving, try Self.render(resting, calm: false, width: Self.size.width, height: Self.size.height))
            let calmKick = Self.delta(
                calm, try Self.render(resting, calm: true, width: Self.size.width, height: Self.size.height))
            #expect(liveKick > calmKick, "kick ripple survived calm (live \(liveKick), calm \(calmKick))")
        }

        /// Headless stills for the look review. Set `NARDUK_MESH_WAVE_DIR` to a directory.
        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func writesReviewStillsWhenAsked() throws {
            guard let dir = ProcessInfo.processInfo.environment["NARDUK_MESH_WAVE_DIR"] else { return }
            let width = 1280
            let height = 720
            let quietState = Self.state(bass: 0.2, mids: 0.06, highs: 0.02, kick: false)
            let loudState = Self.state(bass: 0.95, mids: 0.12, highs: 0.05, kick: false)
            let quiet = try Self.render(quietState, calm: false, width: width, height: height)
            let loud = try Self.render(loudState, calm: false, width: width, height: height)
            try Self.writePNG(quiet, width: width, height: height, path: "\(dir)/mesh-quiet.png")
            try Self.writePNG(loud, width: width, height: height, path: "\(dir)/mesh-loud.png")
            let busy = try Self.render(WobbleTunnelTests.busyState(), calm: false, width: 96, height: 64)
            let cells = WobbleTunnelTests.grid(busy, width: 96, height: 64, columns: 4, rows: 3)
            var luminance: [String] = []
            for index in stride(from: 0, to: cells.count, by: 3) {
                let value = (cells[index] + cells[index + 1] + cells[index + 2]) / 3
                luminance.append(String(format: "%.3f", value))
            }
            print("GOLDEN meshWave: \(luminance.joined(separator: ", "))")
            print("means quiet \(Self.mean(quiet)) loud \(Self.mean(loud))")
        }

        static func writePNG(_ pixels: [UInt8], width: Int, height: Int, path: String) throws {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmap = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
            let data = Data(pixels) as CFData
            let url = URL(fileURLWithPath: path) as CFURL
            guard let provider = CGDataProvider(data: data),
                let image = CGImage(
                    width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: colorSpace, bitmapInfo: bitmap, provider: provider, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent),
                let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
            else {
                Issue.record("could not encode \(path)")
                return
            }
            CGImageDestinationAddImage(dest, image, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
    }
#endif
