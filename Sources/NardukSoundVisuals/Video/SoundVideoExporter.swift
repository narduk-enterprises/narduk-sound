#if canImport(AVFoundation) && canImport(Metal) && canImport(CoreVideo)
    import AVFoundation
    import CoreVideo
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis

    /// The size, rate and codec of an exported video.
    public struct SoundVideoSettings: Sendable, Equatable {
        public enum Codec: Sendable, Equatable {
            /// Plays everywhere (Messages to any phone, the web).
            case h264
            /// About half the size at the same quality; every Apple device since 2017 plays it.
            case hevc
        }

        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        public var codec: Codec
        /// Average video bit rate. The lights are full of fine detail, so this is higher than for a camera clip.
        public var bitsPerSecond: Int
        /// GPU time a frame may take before a light is drawn smaller and scaled up (the live screen's governor does
        /// the same). Nil always draws at full size. 20 ms keeps the heaviest lights near real time on an A14.
        public var gpuBudgetMilliseconds: Double?

        public init(
            width: Int = 720, height: Int = 1280, framesPerSecond: Int = 30, codec: Codec = .h264,
            bitsPerSecond: Int = 4_000_000, gpuBudgetMilliseconds: Double? = 20
        ) {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.codec = codec
            self.bitsPerSecond = bitsPerSecond
            self.gpuBudgetMilliseconds = gpuBudgetMilliseconds
        }
    }

    /// Makes a video of a recorded song: the song's audio (copied as it is, not re-encoded) and the lights drawn
    /// again offline, frame by frame, from the audio and the `SoundVisualTimeline` saved while it recorded. Nothing
    /// is captured from the screen, so recording costs the live picture nothing, and a song saved without a timeline
    /// still gets lights (driven by its audio alone). Runs on the main actor (the renderers live there) and awaits
    /// the GPU between frames, so the UI stays responsive.
    @MainActor
    public final class SoundVideoExporter {
        public enum ExportError: Error, Equatable {
            case noGPU
            case unreadableAudio
            case writerFailed(String)
            /// The GPU refused a frame, most often because the app left the foreground.
            case gpuFailed(String)
        }

        /// What one export measured, for the progress UI and the design note.
        public struct Report: Sendable, Equatable {
            public var frames: Int
            public var seconds: Double
            public var wallSeconds: Double
            public var bytes: Int
            /// The smallest scale any light was drawn at (1 when every light fit the GPU budget).
            public var lowestRenderScale: Double = 1
        }

        public init() {}

        @MainActor public static var isSupported: Bool { IntenseRenderer.shared != nil }

        /// Writes `output` (an `.mp4`; an existing file is replaced). `lights` maps the timeline's light ids to what
        /// to draw; `fallbackLight`, `look` and `calm` apply where the timeline says nothing (no timeline at all, or
        /// an id `lights` does not know). `progress` sees 0 ... 1 on the main actor. Cancelling the task stops the
        /// export, deletes the partial file and throws `CancellationError`.
        @discardableResult
        public func export(
            audio: URL, timeline: SoundVisualTimeline?, to output: URL, settings: SoundVideoSettings = .init(),
            fallbackLight: SoundVideoLight, lights: @escaping (String) -> SoundVideoLight? = { _ in nil },
            look: SoundPaletteLook = .neutral, calm: Bool = false, progress: ((Double) -> Void)? = nil
        ) async throws -> Report {
            let started = Date()
            guard let painter = SoundVideoPainter() else { throw ExportError.noGPU }
            let source = try PCMReader(url: audio)
            let fps = max(settings.framesPerSecond, 1)
            let frameCount = max(1, Int((source.duration * Double(fps)).rounded(.up)))

            try? FileManager.default.removeItem(at: output)
            let writer: AVAssetWriter
            do {
                writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            } catch {
                throw ExportError.writerFailed(error.localizedDescription)
            }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(settings))
            video.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: settings.width,
                    kCVPixelBufferHeightKey as String: settings.height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ])
            guard writer.canAdd(video) else { throw ExportError.writerFailed("cannot add video") }
            writer.add(video)
            let sound = try await AudioPassthrough(url: audio)
            if let input = sound.input, writer.canAdd(input) { writer.add(input) }

            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, painter.device, nil, &cache)
            guard let cache else { throw ExportError.noGPU }

            guard writer.startWriting() else {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "cannot start")
            }
            writer.startSession(atSourceTime: .zero)
            sound.start()

            let scaler = SoundVideoScaler(
                device: painter.device, width: settings.width, height: settings.height,
                budgetMilliseconds: settings.gpuBudgetMilliseconds)
            let scene = SoundVideoScene(
                source: source, timeline: timeline, fallbackLight: fallbackLight, lights: lights, look: look, calm: calm
            )

            do {
                for index in 0..<frameCount {
                    try Task.checkCancellation()
                    let time = Double(index) / Double(fps)
                    let light = try scene.advance(to: time)

                    while !video.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        throw ExportError.writerFailed(writer.error?.localizedDescription ?? "no pixel buffer pool")
                    }
                    var pixels: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
                    guard let pixels else { throw ExportError.writerFailed("no pixel buffer") }
                    var wrapped: CVMetalTexture?
                    CVMetalTextureCacheCreateTextureFromImage(
                        nil, cache, pixels, nil, IntenseRenderer.pixelFormat, settings.width, settings.height, 0,
                        &wrapped)
                    guard let wrapped, let target = CVMetalTextureGetTexture(wrapped),
                        let buffer = painter.queue.makeCommandBuffer()
                    else { throw ExportError.noGPU }
                    let scale = scaler.scale(for: light)
                    if scale < 1, let small = scaler.texture(scale: scale) {
                        painter.encode(light, buffer: buffer, target: small, state: scene.state)
                        scaler.encodeUpscale(from: small, to: target, buffer: buffer)
                    } else {
                        painter.encode(light, buffer: buffer, target: target, state: scene.state)
                    }
                    // A frame the GPU refused (the app went to the background) fails the export, never a black frame.
                    let failure = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                        buffer.addCompletedHandler { finished in
                            done.resume(
                                returning: finished.status == .error
                                    ? (finished.error?.localizedDescription ?? "the GPU stopped") : nil)
                        }
                        buffer.commit()
                    }
                    if let failure { throw ExportError.gpuFailed(failure) }
                    scaler.record(light, milliseconds: (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                    withExtendedLifetime(wrapped) {}
                    guard
                        adaptor.append(
                            pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
                        )
                    else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "append failed") }
                    sound.pump(through: time + 1)
                    if index % 5 == 0 || index == frameCount - 1 { progress?(Double(index + 1) / Double(frameCount)) }
                }
                while !sound.isDone {
                    try Task.checkCancellation()
                    sound.pump(through: .infinity)
                    if !sound.isDone { try await Task.sleep(for: .milliseconds(2)) }
                }
            } catch {
                sound.cancel()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            video.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: output)
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "finish failed")
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
            return Report(
                frames: frameCount, seconds: source.duration, wallSeconds: Date().timeIntervalSince(started),
                bytes: bytes, lowestRenderScale: scaler.lowestScale)
        }

        static func videoSettings(_ settings: SoundVideoSettings) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: settings.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: settings.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: settings.framesPerSecond * 2,
            ]
            if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            return [
                AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: settings.width,
                AVVideoHeightKey: settings.height,
                AVVideoCompressionPropertiesKey: compression,
            ]
        }
    }

    /// The picture's inputs at each video frame: the audio's trailing window, analyzed as the live source would, and
    /// the timeline's music, light, look and calm. `advance` moves `state` to a time and returns the light to draw.
    @MainActor
    final class SoundVideoScene {
        let state = SoundVisualState()
        private let source: PCMReader
        private let timeline: SoundVisualTimeline?
        private let fallbackLight: SoundVideoLight
        private let lights: (String) -> SoundVideoLight?
        private let look: SoundPaletteLook
        private let calm: Bool
        private let analyzer: SoundAnalyzer
        private var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
        private var currentLook: SoundPaletteLook?

        init(
            source: PCMReader, timeline: SoundVisualTimeline?, fallbackLight: SoundVideoLight,
            lights: @escaping (String) -> SoundVideoLight?, look: SoundPaletteLook, calm: Bool
        ) {
            self.source = source
            self.timeline = timeline
            self.fallbackLight = fallbackLight
            self.lights = lights
            self.look = look
            self.calm = calm
            analyzer = SoundAnalyzer(sampleRate: source.sampleRate)
        }

        /// The live screen updates the state at 60 Hz, and some lights integrate motion per update, so a 30 fps
        /// video steps the state at 60 Hz too and draws every other step.
        static let stepRate = 60.0
        private var lastTime: Double?

        func advance(to time: Double) throws -> SoundVideoLight {
            if let lastTime {
                var step = lastTime + 1 / Self.stepRate
                while step < time - 0.001 {
                    _ = try update(at: step)
                    step += 1 / Self.stepRate
                }
            }
            lastTime = time
            return try update(at: time)
        }

        private func update(at time: Double) throws -> SoundVideoLight {
            try source.window(endingAt: Int(time * source.sampleRate), into: &window)
            let frame = window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
            let id = timeline.flatMap { SoundVisualTimeline.value(of: $0.lights, at: time) }
            let light = id.flatMap(lights) ?? fallbackLight
            let wantLook = timeline.flatMap { SoundVisualTimeline.value(of: $0.looks, at: time) } ?? look
            if wantLook != currentLook {
                if currentLook == nil {
                    // The first look applies at once (it was on screen before the recording began); later ones ease
                    // in as they did live.
                    let ease = state.lookEaseDuration
                    state.lookEaseDuration = 0
                    state.look = wantLook
                    state.update(SoundVisualInput(frame: SoundFrame()), now: time - 0.01)
                    state.lookEaseDuration = ease
                } else {
                    state.look = wantLook
                }
                currentLook = wantLook
            }
            let isCalm = timeline.flatMap { SoundVisualTimeline.value(of: $0.calm, at: time) } ?? calm
            state.update(
                SoundVisualInput(frame: frame, music: timeline?.music(at: time)), now: time,
                options: SoundVisualOptions(calm: isCalm))
            return light
        }
    }

    /// Reads an audio file forward as mono floats and hands out the trailing analysis window at any later sample.
    @MainActor
    final class PCMReader {
        let sampleRate: Double
        let duration: Double
        private let file: AVAudioFile
        private let chunk: AVAudioPCMBuffer
        /// Decoded mono samples; `pcm[0]` is sample `start` of the file.
        private var pcm: [Float] = []
        private var start = 0
        private var decoded = 0

        init(url: URL) throws {
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0,
                let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
            else { throw SoundVideoExporter.ExportError.unreadableAudio }
            self.file = file
            self.chunk = chunk
            sampleRate = file.processingFormat.sampleRate
            duration = Double(file.length) / sampleRate
        }

        /// Fills `window` with the samples just before `end` (silence before the start and past the end).
        func window(endingAt end: Int, into window: inout [Float]) throws {
            while decoded < end, decoded < Int(file.length) {
                chunk.frameLength = 0
                try file.read(
                    into: chunk, frameCount: min(chunk.frameCapacity, AVAudioFrameCount(Int(file.length) - decoded)))
                let frames = Int(chunk.frameLength)
                if frames == 0 { break }
                guard let channels = chunk.floatChannelData else {
                    throw SoundVideoExporter.ExportError.unreadableAudio
                }
                let count = Int(chunk.format.channelCount)
                let scale = 1 / Float(max(count, 1))
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<count { sum += channels[c][i] }
                    pcm.append(sum * scale)
                }
                decoded += frames
            }
            let size = window.count
            // Keep a little more than one window behind the playhead.
            let keepFrom = end - size * 2
            if keepFrom - start > size * 8 {
                pcm.removeFirst(keepFrom - start)
                start = keepFrom
            }
            for i in 0..<size {
                let sample = end - size + i
                let local = sample - start
                window[i] = local >= 0 && local < pcm.count ? pcm[local] : 0
            }
        }
    }

    /// Copies the song's compressed audio into the video unchanged.
    @MainActor
    final class AudioPassthrough {
        let input: AVAssetWriterInput?
        private let reader: AVAssetReader?
        private let output: AVAssetReaderTrackOutput?
        private var pending: CMSampleBuffer?
        private(set) var isDone = false

        init(url: URL) async throws {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw SoundVideoExporter.ExportError.unreadableAudio
            }
            let hint = try await track.load(.formatDescriptions).first
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw SoundVideoExporter.ExportError.unreadableAudio }
            reader.add(output)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            self.reader = reader
            self.output = output
            self.input = input
        }

        func start() {
            guard reader?.startReading() == true else {
                isDone = true
                input?.markAsFinished()
                return
            }
        }

        /// Appends audio up to `time` seconds while the writer takes it.
        func pump(through time: Double) {
            guard !isDone, let input, let output else { return }
            while input.isReadyForMoreMediaData {
                if pending == nil { pending = output.copyNextSampleBuffer() }
                guard let buffer = pending else {
                    input.markAsFinished()
                    isDone = true
                    return
                }
                if CMSampleBufferGetPresentationTimeStamp(buffer).seconds > time { return }
                input.append(buffer)
                pending = nil
            }
        }

        func cancel() {
            reader?.cancelReading()
        }
    }
#endif
