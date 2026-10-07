#if canImport(AVFoundation) && canImport(Metal) && canImport(MetalPerformanceShaders)
    import AVFoundation
    import CoreVideo
    import Foundation
    import Metal
    import MetalPerformanceShaders
    import Testing

    @testable import NardukSoundVisuals

    /// The numbers behind the video share design (beat-blaster docs/video-share.md). Off by default: set
    /// `NARDUK_VIDEO_BENCH=1` (`TEST_RUNNER_NARDUK_VIDEO_BENCH=1` through xcodebuild on a device). Prints `BENCH` lines.
    ///
    /// - A, live capture: the extra GPU time a frame costs when the live picture is also scaled into a video pixel
    ///   buffer and handed to a real-time writer, at the live drawable size of an iPad 10th gen.
    /// - B, offline export: wall time and file size of exporting a song, by size, codec and light.
    /// - Fidelity: how far the offline picture (AAC re-analyzed, music from the 30 Hz timeline) is from the live one
    ///   (exact samples and music every 60 Hz tick), against how far the live picture moves in one video frame.
    @MainActor @Suite(.serialized) struct SoundVideoBenchmarkTests {
        nonisolated static let enabled =
            ProcessInfo.processInfo.environment["NARDUK_VIDEO_BENCH"] == "1" && MTLCreateSystemDefaultDevice() != nil
        static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundVideoBenchmark", isDirectory: true)

        static let lights: [(String, SoundVideoLight)] = [
            ("tunnel", .tunnel),
            ("plasma", .shaderPack(.plasma)),
            ("feedback", .shaderPack(.feedback)),
            ("liquidSplash", .intense(.liquidSplash)),
            ("fractalDive", .intense(.fractalDive)),
            ("sun", .intense(.sun)),
            ("jellyfish", .intense(.jellyfish)),
        ]

        static func report(_ line: String) {
            print("BENCH \(line)")
        }

        @Test(.enabled(if: enabled)) func liveCaptureCost() async throws {
            let song = try VideoSongFixture.make(seconds: 4, directory: Self.directory)
            guard let painter = SoundVideoPainter() else { return }
            let device = painter.device
            // iPad 10th gen: 820 x 1180 pt at 2x, drawn at the governor's top scale (0.75).
            let live = (width: 1230, height: 1770)
            let video = (width: 720, height: 1280)
            let drawable = try #require(Self.texture(device: device, width: live.width, height: live.height))
            let scaler = MPSImageBilinearScale(device: device)
            let writerURL = Self.directory.appendingPathComponent("capture.mp4")
            try? FileManager.default.removeItem(at: writerURL)
            let writer = try AVAssetWriter(outputURL: writerURL, fileType: .mp4)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: SoundVideoExporter.videoSettings(
                    SoundVideoSettings(width: video.width, height: video.height, framesPerSecond: 60)))
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: video.width, kCVPixelBufferHeightKey as String: video.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            let textureCache = try #require(cache)
            var appendIndex: Int64 = 0

            for (name, light) in Self.lights {
                var plain: [Double] = []
                var captured: [Double] = []
                var cpu: [Double] = []
                let state = SoundVisualState()
                for (i, tick) in song.live.prefix(180).enumerated() {
                    state.update(tick.input, now: tick.time)
                    let capture = i % 2 == 1
                    guard let buffer = painter.queue.makeCommandBuffer() else { continue }
                    painter.encode(light, buffer: buffer, target: drawable, state: state)
                    let cpuStart = CACurrentMediaTime()
                    var pixels: CVPixelBuffer?
                    var wrapped: CVMetalTexture?
                    if capture, let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
                        if let pixels {
                            CVMetalTextureCacheCreateTextureFromImage(
                                nil, textureCache, pixels, nil, .bgra8Unorm, video.width, video.height, 0, &wrapped)
                        }
                        if let wrapped, let target = CVMetalTextureGetTexture(wrapped) {
                            scaler.encode(commandBuffer: buffer, sourceTexture: drawable, destinationTexture: target)
                        }
                    }
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        buffer.addCompletedHandler { _ in done.resume() }
                        buffer.commit()
                    }
                    if capture, let pixels, input.isReadyForMoreMediaData {
                        adaptor.append(pixels, withPresentationTime: CMTime(value: appendIndex, timescale: 60))
                        appendIndex += 1
                    }
                    let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    if i >= 20 {
                        if capture {
                            captured.append(gpuMs)
                            cpu.append((CACurrentMediaTime() - cpuStart) * 1000)
                        } else {
                            plain.append(gpuMs)
                        }
                    }
                }
                Self.report(
                    "A light=\(name) size=\(live.width)x\(live.height) render_gpu_ms=\(Self.median(plain).f2) "
                        + "render+capture_gpu_ms=\(Self.median(captured).f2) "
                        + "added_gpu_ms=\((Self.median(captured) - Self.median(plain)).f2) "
                        + "capture_cpu_ms=\(Self.median(cpu).f2)")
            }
            input.markAsFinished()
            await writer.finishWriting()
        }

        @Test(.enabled(if: enabled)) func offlineExportCost() async throws {
            let song = try VideoSongFixture.make(seconds: 20, directory: Self.directory)
            // "-gov" is the shipping default (a 20 ms GPU budget); the rest draw at full size to compare.
            let configs: [(String, SoundVideoSettings, [(String, SoundVideoLight)])] = [
                ("720x1280-h264-4M-gov", SoundVideoSettings(width: 720, height: 1280), Self.lights),
                (
                    "720x1280-h264-4M", SoundVideoSettings(width: 720, height: 1280, gpuBudgetMilliseconds: nil),
                    Self.lights
                ),
                (
                    "1080x1920-h264-8M",
                    SoundVideoSettings(width: 1080, height: 1920, bitsPerSecond: 8_000_000, gpuBudgetMilliseconds: nil),
                    [Self.lights[0], Self.lights[5]]
                ),
                (
                    "1080x1080-h264-6M",
                    SoundVideoSettings(width: 1080, height: 1080, bitsPerSecond: 6_000_000, gpuBudgetMilliseconds: nil),
                    [Self.lights[0], Self.lights[5]]
                ),
                (
                    "720x1280-hevc-2.5M",
                    SoundVideoSettings(
                        width: 720, height: 1280, codec: .hevc, bitsPerSecond: 2_500_000, gpuBudgetMilliseconds: nil),
                    [Self.lights[0], Self.lights[5]]
                ),
            ]
            let only = ProcessInfo.processInfo.environment["NARDUK_VIDEO_BENCH_CONFIG"].flatMap {
                $0.isEmpty ? nil : $0
            }
            for (configName, settings, lights) in configs where only == nil || only == configName {
                for (name, light) in lights {
                    let output = Self.directory.appendingPathComponent("\(configName)-\(name).mp4")
                    let report = try await SoundVideoExporter().export(
                        audio: song.audio, timeline: song.timeline, to: output, settings: settings,
                        fallbackLight: light)
                    let perSongSecond = report.wallSeconds / report.seconds
                    Self.report(
                        "B config=\(configName) light=\(name) song_s=\(report.seconds.f2) wall_s=\(report.wallSeconds.f2) "
                            + "wall_per_song_s=\(perSongSecond.f2) est_3min_s=\((perSongSecond * 180).f2) "
                            + "MB_per_min=\((Double(report.bytes) / 1_048_576 / report.seconds * 60).f2) "
                            + "scale=\(report.lowestRenderScale.f2)")
                    try? FileManager.default.removeItem(at: output)
                }
            }
        }

        @Test(.enabled(if: enabled)) func offlineMatchesLive() throws {
            let song = try VideoSongFixture.make(seconds: 12, directory: Self.directory)
            let size = (width: 270, height: 480)
            guard let livePainter = SoundVideoPainter(), let offlinePainter = SoundVideoPainter(),
                let audioOnlyPainter = SoundVideoPainter()
            else { return }
            let device = livePainter.device
            let a = try #require(Self.texture(device: device, width: size.width, height: size.height))
            let b = try #require(Self.texture(device: device, width: size.width, height: size.height))
            let c = try #require(Self.texture(device: device, width: size.width, height: size.height))
            for (name, light) in Self.lights {
                let liveState = SoundVisualState()
                let offline = SoundVideoScene(
                    source: try PCMReader(url: song.audio), timeline: song.timeline, fallbackLight: light,
                    lights: { _ in nil }, look: .neutral, calm: false)
                let audioOnly = SoundVideoScene(
                    source: try PCMReader(url: song.audio), timeline: nil, fallbackLight: light, lights: { _ in nil },
                    look: .neutral, calm: false)
                var previousLive: [UInt8]?
                var offlineDiff: [Double] = []
                var audioOnlyDiff: [Double] = []
                var motion: [Double] = []
                for (i, tick) in song.live.enumerated() {
                    liveState.update(tick.input, now: tick.time)
                    guard i % 2 == 1 else { continue }  // 30 fps: the video's frames
                    _ = try offline.advance(to: tick.time)
                    _ = try audioOnly.advance(to: tick.time)
                    let livePixels = try #require(Self.draw(light, painter: livePainter, state: liveState, into: a))
                    let offlinePixels = try #require(
                        Self.draw(light, painter: offlinePainter, state: offline.state, into: b))
                    let audioPixels = try #require(
                        Self.draw(light, painter: audioOnlyPainter, state: audioOnly.state, into: c))
                    if tick.time > 2 {
                        offlineDiff.append(Self.meanAbsoluteDifference(livePixels, offlinePixels))
                        audioOnlyDiff.append(Self.meanAbsoluteDifference(livePixels, audioPixels))
                        if let previousLive { motion.append(Self.meanAbsoluteDifference(previousLive, livePixels)) }
                    }
                    previousLive = livePixels
                }
                Self.report(
                    "F light=\(name) offline_vs_live=\(Self.mean(offlineDiff).f2) "
                        + "audio_only_vs_live=\(Self.mean(audioOnlyDiff).f2) "
                        + "live_one_frame_motion=\(Self.mean(motion).f2) (mean abs difference per channel, 0-255)")
            }
        }

        // MARK: Helpers

        static func texture(device: any MTLDevice, width: Int, height: Int) -> (any MTLTexture)? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }

        static func draw(
            _ light: SoundVideoLight, painter: SoundVideoPainter, state: SoundVisualState, into texture: any MTLTexture
        ) -> [UInt8]? {
            guard let buffer = painter.queue.makeCommandBuffer() else { return nil }
            painter.encode(light, buffer: buffer, target: texture, state: state)
            buffer.commit()
            buffer.waitUntilCompleted()
            var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            texture.getBytes(
                &pixels, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return pixels
        }

        static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var sum = 0
            var i = 0
            while i < a.count {
                sum +=
                    abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                i += 4
            }
            return Double(sum) / Double(a.count / 4 * 3)
        }

        static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }

        static func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    extension Double {
        fileprivate var f2: String { String(format: "%.2f", self) }
    }
#endif
