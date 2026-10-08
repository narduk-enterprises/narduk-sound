#if canImport(AVFoundation) && canImport(Metal)
    import AVFoundation
    import CoreVideo
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukMusicDSP
    import NardukMusicRender
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// Headless clips of the Sun over the classic loop: the engine's own `MusicContext` (what the demo song shows)
    /// against the same samples heard back through `SoundMusicInference`. No window, no audio device: the song is
    /// rendered in memory, drawn offscreen, and written as silent H.264 by `AVAssetWriter`. `SUN_CLIP_OUT=<dir>`
    /// writes `sun-demo.mp4`, `sun-heard.mp4` and a per-frame `sun-frames.csv` (luma and motion for both).
    @Suite struct SunClipTests {
        static let width = 960
        static let height = 540
        static let seconds = Double(ProcessInfo.processInfo.environment["SUN_CLIP_SECONDS"] ?? "") ?? 10

        /// Appends BGRA frames at 60 fps.
        final class ClipWriter {
            let writer: AVAssetWriter
            let input: AVAssetWriterInput
            let adaptor: AVAssetWriterInputPixelBufferAdaptor
            var frame = 0

            init(url: URL, width: Int, height: Int) throws {
                try? FileManager.default.removeItem(at: url)
                writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                input = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
                    ])
                input.expectsMediaDataInRealTime = false
                adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: input,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                    ])
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                writer.startSession(atSourceTime: .zero)
            }

            func append(_ pixels: [UInt8], width: Int, height: Int) throws {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                pixels.withUnsafeBufferPointer { source in
                    for row in 0..<height {
                        memcpy(base + row * rowBytes, source.baseAddress! + row * width * 4, width * 4)
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                let time = CMTime(value: CMTimeValue(frame), timescale: 60)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += 1
            }

            func finish() throws {
                input.markAsFinished()
                let done = DispatchSemaphore(value: 0)
                writer.finishWriting { done.signal() }
                done.wait()
                if let error = writer.error { throw error }
            }
        }

        struct FrameStat {
            var luma: Float
            var motion: Float
        }

        /// Renders the loop, drives the state from the engine or the inference, draws the Sun per frame and writes
        /// the clip. Returns the mean luma and motion (mean absolute change from the previous frame) per frame.
        @MainActor
        static func render(inferred: Bool, to url: URL) throws -> [FrameStat] {
            let settings = SongSettings()
            let renderer = OfflineRenderer(settings: settings, playsConductor: false)
            renderer.schedule(DemoPattern.notes(in: 0...(Int(seconds / settings.secondsPerStep) + 1)))
            let analyzer = SoundAnalyzer(sampleRate: renderer.sampleRate)
            let inference = SoundMusicInference()
            let state = SoundVisualState()
            var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
            var counts = HitCounters()

            let metal = try #require(IntenseRenderer(device: MTLCreateSystemDefaultDevice()))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: IntenseRenderer.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = metal.device.hasUnifiedMemory ? .shared : .managed
            let texture = try #require(metal.device.makeTexture(descriptor: descriptor))
            var limiter = IntenseFlashLimiter()
            var uniforms = IntenseUniforms()
            var motion = IntenseMotion()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            var previous = pixels
            let clip = try ClipWriter(url: url, width: width, height: height)
            var stats: [FrameStat] = []

            let frames = Int(seconds * OfflineRenderer.tickRate)
            for tick in 0..<frames {
                let time = Double(tick + 1) / OfflineRenderer.tickRate
                _ = renderer.advance()
                for hit in renderer.takeHits() { counts.record(hit) }
                window.withUnsafeMutableBufferPointer { renderer.copyRecentSamples(into: $0) }
                let frame = window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
                let music: MusicContext
                if inferred {
                    music = inference.update(frame)
                } else {
                    let step = renderer.currentStep
                    music = MusicContext(
                        hitCounts: counts, step: step, section: DemoPattern.section(atStep: step), energy: 0,
                        wobblePhase: 0, wobbleCutoff: 0, isRunning: true, secondsPerStep: settings.secondsPerStep,
                        stepsPerBar: settings.stepsPerBar, stepsPerPhrase: settings.stepsPerPhrase,
                        phraseProgress: Float(step % settings.stepsPerPhrase) / Float(settings.stepsPerPhrase),
                        buildThreshold: 0.55, dropThreshold: 0.4, dropQueued: false)
                }
                state.update(SoundVisualInput(frame: frame, music: music), now: time)

                let buffer = try #require(metal.queue.makeCommandBuffer())
                let drive = IntenseDrive(state: state, limiter: &limiter)
                motion.advance(.sun, state: state, intensity: drive.intensity)
                metal.encode(
                    .sun, buffer: buffer, target: texture, state: state, drive: drive, uniforms: &uniforms,
                    surface: nil, motion: motion)
                if !metal.device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
                    blit.synchronize(resource: texture)
                    blit.endEncoding()
                }
                buffer.commit()
                buffer.waitUntilCompleted()
                try #require(buffer.status == .completed)
                texture.getBytes(
                    &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                try clip.append(pixels, width: width, height: height)

                var sum = 0
                var diff = 0
                var i = 0
                while i < pixels.count {
                    sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                    diff +=
                        abs(Int(pixels[i]) - Int(previous[i])) + abs(Int(pixels[i + 1]) - Int(previous[i + 1]))
                        + abs(Int(pixels[i + 2]) - Int(previous[i + 2]))
                    i += 4
                }
                let scale = Float(width * height * 3 * 255)
                stats.append(FrameStat(luma: Float(sum) / scale, motion: Float(diff) / scale))
                swap(&pixels, &previous)
            }
            try clip.finish()
            return stats
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["SUN_CLIP_OUT"] != nil))
        @MainActor func writeBothClips() throws {
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUN_CLIP_OUT"]!)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let started = Date()
            let demo = try Self.render(inferred: false, to: dir.appendingPathComponent("sun-demo.mp4"))
            let heard = try Self.render(inferred: true, to: dir.appendingPathComponent("sun-heard.mp4"))
            var csv = "frame,seconds,demo_luma,demo_motion,heard_luma,heard_motion\n"
            for (index, (a, b)) in zip(demo, heard).enumerated() {
                csv += String(
                    format: "%d,%.3f,%.4f,%.4f,%.4f,%.4f\n", index, Double(index) / 60, a.luma, a.motion, b.luma,
                    b.motion)
            }
            try csv.write(to: dir.appendingPathComponent("sun-frames.csv"), atomically: true, encoding: .utf8)
            print(String(format: "sunclip: %d frames each in %.1f s", demo.count, Date().timeIntervalSince(started)))
        }
    }
#endif
