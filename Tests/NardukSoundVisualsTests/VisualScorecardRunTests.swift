#if canImport(AVFoundation) && canImport(Metal)
    import AVFoundation
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// The headless visualizer scorecard (docs/visual-scorecard.md). Skipped unless `SCORE_TIMELINES=<a>:<b>` and
    /// `SCORE_OUT=<dir>` are set. For every recorded song and every visualizer the gallery shows (the intense kinds, the
    /// shader pack, the wobble tunnel) it draws a ~60 s window of the song offscreen at 60 fps, reduces each frame to
    /// luma, spread, motion and hue, and scores how the picture follows the music (`VisualScorecard`). No window, no
    /// audio device, no screen recording.
    ///
    /// Optional environment: `SCORE_VIDEO=1` (silent mp4 per run), `SCORE_SECONDS` (window length, 60),
    /// `SCORE_WINDOW_START` (seconds; default: the window with the widest loudness range), `SCORE_SIZE` (`480x270`),
    /// `SCORE_KINDS` (comma list of visualizer ids; default all), `SCORE_TRANSFORMS` (`identity,rescale`),
    /// `SCORE_RESUME=1` (skip a run whose row already exists in `SCORE_OUT/rows`).
    @MainActor @Suite struct VisualScorecardRunTests {
        typealias Drawer = @MainActor (SoundVisualState, any MTLCommandBuffer, any MTLTexture) -> Void

        /// One visualizer the gallery shows, and how to build a fresh drawer for it (fresh motion, limiter and
        /// feedback state per run).
        struct Target {
            let id: String
            let title: String
            let make: @MainActor (Renderers, Int, Int) -> Drawer?
        }

        @MainActor final class Renderers {
            let intense: IntenseRenderer
            let pack: ShaderPackRenderer
            let tunnel: WobbleTunnelRenderer

            init?() {
                guard let device = MTLCreateSystemDefaultDevice(), let intense = IntenseRenderer(device: device),
                    let pack = ShaderPackRenderer(device: device), let tunnel = WobbleTunnelRenderer(device: device)
                else { return nil }
                self.intense = intense
                self.pack = pack
                self.tunnel = tunnel
            }
        }

        /// The gallery's tiles: the wobble tunnel, the shader pack and every built-in intense kind.
        static var targets: [Target] {
            var out: [Target] = []
            out.append(
                Target(id: "wobbleTunnel", title: "Wobble tunnel") { renderers, _, _ in
                    var uniforms = WobbleTunnelUniforms()
                    let tunnel = renderers.tunnel
                    return { state, buffer, texture in
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = texture
                        pass.colorAttachments[0].loadAction = .clear
                        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                        pass.colorAttachments[0].storeAction = .store
                        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
                        tunnel.encode(
                            into: encoder, size: CGSize(width: texture.width, height: texture.height), state: state,
                            uniforms: &uniforms)
                        encoder.endEncoding()
                    }
                })
            for kind in ShaderPackKind.allCases {
                out.append(
                    Target(id: "pack." + kind.rawValue, title: kind.title) { renderers, width, height in
                        var uniforms = WobbleTunnelUniforms()
                        let pack = renderers.pack
                        let surface =
                            kind == .feedback
                            ? FeedbackSurface(device: pack.device, width: width, height: height) : nil
                        if kind == .feedback, surface == nil { return nil }
                        return { state, buffer, texture in
                            pack.encode(
                                kind, buffer: buffer, target: texture, state: state, calm: false, uniforms: &uniforms,
                                surface: surface)
                        }
                    })
            }
            for kind in IntenseKind.allCases {
                out.append(
                    Target(id: kind.id, title: kind.title) { renderers, width, height in
                        let metal = renderers.intense
                        var limiter = IntenseFlashLimiter()
                        var uniforms = IntenseUniforms()
                        var motion = IntenseMotion()
                        let surface =
                            kind.usesFeedback
                            ? FeedbackSurface(device: metal.device, width: width, height: height) : nil
                        if kind.usesFeedback, surface == nil { return nil }
                        return { state, buffer, texture in
                            let drive = IntenseDrive(state: state, limiter: &limiter)
                            motion.advance(kind, state: state, intensity: drive.intensity)
                            metal.encode(
                                kind, buffer: buffer, target: texture, state: state, drive: drive, uniforms: &uniforms,
                                surface: surface, motion: motion)
                        }
                    })
            }
            return out
        }

        struct RunResult {
            var frames: [VisualScorecard.Frame]
            var inputs: [VisualScorecard.Input]
        }

        /// Draws `seconds` of the song from `start` through `drawer`, after one second of warm-up (state, motion and
        /// feedback settle; those frames are not scored). `transform` is applied before the state sees the input.
        static func render(
            drawer: Drawer, renderers: Renderers, timeline: SoundTimeline, transform: VisualScorecard.Transform,
            start: Double, seconds: Double, width: Int, height: Int, video: URL?
        ) throws -> RunResult {
            let queue = renderers.intense.queue
            let device = renderers.intense.device
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: IntenseRenderer.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let player = SoundTimelinePlayer(timeline)
            let state = SoundVisualState()
            let clip = try video.map { try SunClipTests.ClipWriter(url: $0, width: width, height: height) }

            let count = width * height
            var pixels = [UInt8](repeating: 0, count: count * 4)
            var previous = pixels
            var histogram = [Int](repeating: 0, count: 256)
            var frames: [VisualScorecard.Frame] = []
            var inputs: [VisualScorecard.Input] = []
            frames.reserveCapacity(Int(seconds * VisualScorecard.fps))
            var lastKick: UInt32?
            var lastSnare: UInt32?

            let warm = 60
            let total = warm + Int(seconds * VisualScorecard.fps)
            for k in 0..<total {
                let time = max(start + Double(k - warm) / VisualScorecard.fps, 0)
                let raw = player.input(at: time)
                let counts = raw.music?.hitCounts ?? HitCounters()
                let kick = counts[.kick]
                let snare = counts[.snare]
                let kicked = lastKick.map { kick != $0 } ?? false
                let snared = lastSnare.map { snare != $0 } ?? false
                lastKick = kick
                lastSnare = snare
                state.update(transform(raw), now: time)

                let buffer = try #require(queue.makeCommandBuffer())
                drawer(state, buffer, texture)
                if !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
                    blit.synchronize(resource: texture)
                    blit.endEncoding()
                }
                buffer.commit()
                buffer.waitUntilCompleted()
                try #require(
                    buffer.status == .completed, "a command buffer failed: \(String(describing: buffer.error))")
                texture.getBytes(
                    &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                if k >= warm { try clip?.append(pixels, width: width, height: height) }

                // BGRA: luma histogram, mean colour and change from the previous frame in one pass.
                for i in 0..<256 { histogram[i] = 0 }
                var lumaSum = 0
                var diff = 0
                var sumR = 0
                var sumG = 0
                var sumB = 0
                pixels.withUnsafeBufferPointer { now in
                    previous.withUnsafeBufferPointer { before in
                        var i = 0
                        let end = count * 4
                        while i < end {
                            let b = Int(now[i])
                            let g = Int(now[i + 1])
                            let r = Int(now[i + 2])
                            let y = (29 * b + 150 * g + 77 * r) >> 8
                            histogram[y] += 1
                            lumaSum += y
                            sumR += r
                            sumG += g
                            sumB += b
                            diff +=
                                abs(b - Int(before[i])) + abs(g - Int(before[i + 1])) + abs(r - Int(before[i + 2]))
                            i += 4
                        }
                    }
                }
                swap(&pixels, &previous)
                guard k >= warm else { continue }

                func quantile(_ q: Double) -> Double {
                    let target = Int((q * Double(count)).rounded(.up))
                    var running = 0
                    for i in 0..<256 {
                        running += histogram[i]
                        if running >= target { return Double(i) / 255 }
                    }
                    return 1
                }
                let n = Double(count)
                let color = VisualScorecard.hueSaturation(
                    r: Double(sumR) / n / 255, g: Double(sumG) / n / 255, b: Double(sumB) / n / 255)
                frames.append(
                    VisualScorecard.Frame(
                        luma: Float(Double(lumaSum) / n / 255), spread: Float(quantile(0.9) - quantile(0.1)),
                        motion: Float(Double(diff) / (n * 3 * 255)), hue: color.hue, saturation: color.saturation))
                inputs.append(VisualScorecard.Input(rmsDB: raw.frame.rmsDB, kick: kicked, snare: snared))
            }
            try clip?.finish()
            return RunResult(frames: frames, inputs: inputs)
        }

        // MARK: Output

        static func framesCSV(_ result: RunResult) -> String {
            var csv = "frame,seconds,luma,spread,motion,hue,saturation,rms_db,kick,snare\n"
            for (i, (f, input)) in zip(result.frames, result.inputs).enumerated() {
                csv += String(
                    format: "%d,%.4f,%.5f,%.5f,%.5f,%.4f,%.4f,%.2f,%d,%d\n", i, Double(i) / VisualScorecard.fps,
                    f.luma, f.spread, f.motion, f.hue, f.saturation, input.rmsDB, input.kick ? 1 : 0,
                    input.snare ? 1 : 0)
            }
            return csv
        }

        // MARK: The test

        nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }
        nonisolated static var enabled: Bool {
            environment["SCORE_TIMELINES"] != nil && environment["SCORE_OUT"] != nil
        }

        @Test(.enabled(if: VisualScorecardRunTests.enabled, "set SCORE_TIMELINES and SCORE_OUT to run the scorecard"))
        func scoreEveryVisualizerOverRecordedSongs() throws {
            let env = Self.environment
            let out = URL(fileURLWithPath: try #require(env["SCORE_OUT"]))
            let rows = out.appendingPathComponent("rows")
            let framesDir = out.appendingPathComponent("frames")
            let videoDir = out.appendingPathComponent("video")
            for dir in [out, rows, framesDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let wantVideo = env["SCORE_VIDEO"] == "1"
            if wantVideo { try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true) }

            let seconds = Double(env["SCORE_SECONDS"] ?? "") ?? 60
            let size = (env["SCORE_SIZE"] ?? "480x270").split(separator: "x").compactMap { Int($0) }
            let (width, height) = size.count == 2 ? (size[0], size[1]) : (480, 270)
            let kindFilter = env["SCORE_KINDS"].map { Set($0.split(separator: ",").map(String.init)) }
            let transformNames = (env["SCORE_TRANSFORMS"] ?? "identity,rescale").split(separator: ",").map(String.init)
            let resume = env["SCORE_RESUME"] == "1"
            let files = try #require(env["SCORE_TIMELINES"]).split(separator: ":").map(String.init)
            let renderers = try #require(Renderers(), "no Metal device, or a shader did not compile")
            let targets = Self.targets.filter { kindFilter?.contains($0.id) ?? true }
            let started = Date()
            var done = 0

            for file in files {
                let url = URL(fileURLWithPath: file)
                let song = url.deletingPathExtension().lastPathComponent
                let timeline = try SoundTimeline(decoding: Data(contentsOf: url))
                let length = min(seconds, max(timeline.duration - 2, 5))
                let start =
                    Double(env["SCORE_WINDOW_START"] ?? "")
                    ?? VisualScorecard.chooseWindow(
                        rmsDB: (0..<timeline.sampleCount).map { Double(timeline.rmsCentiDB[$0]) / 100 },
                        gridRate: timeline.gridRate, seconds: length)
                FileHandle.standardError.write(
                    Data(String(format: "scorecard: %@ window %.1f s for %.0f s\n", song, start, length).utf8))
                let transforms: [(String, VisualScorecard.Transform)] = transformNames.compactMap { name in
                    switch name {
                    case "identity": (name, VisualScorecard.identity)
                    case "rescale": (name, VisualScorecard.rescale(timeline))
                    default: nil
                    }
                }
                for (transformName, transform) in transforms {
                    for target in targets {
                        let stem = "\(song)-\(transformName)-\(target.id)"
                        let rowURL = rows.appendingPathComponent(stem + ".csv")
                        if resume, FileManager.default.fileExists(atPath: rowURL.path) { continue }
                        let runStarted = Date()
                        guard let drawer = target.make(renderers, width, height) else {
                            Issue.record("\(target.id): could not build the drawer")
                            continue
                        }
                        let result = try Self.render(
                            drawer: drawer, renderers: renderers, timeline: timeline, transform: transform,
                            start: start, seconds: length, width: width, height: height,
                            video: wantVideo ? videoDir.appendingPathComponent(stem + ".mp4") : nil)
                        let metrics = VisualScorecard.score(frames: result.frames, inputs: result.inputs)
                        try Self.framesCSV(result).write(
                            to: framesDir.appendingPathComponent(stem + ".csv"), atomically: true, encoding: .utf8)
                        let line = ScorecardReport.rowLine(
                            song: song, transform: transformName, id: target.id, title: target.title, start: start,
                            m: metrics)
                        try (line + "\n").write(to: rowURL, atomically: true, encoding: .utf8)
                        done += 1
                        let message = String(
                            format: "scorecard: %@ %@ %@ %d frames in %.1f s (%d done, %.0f s elapsed)\n", song,
                            transformName, target.id, result.frames.count, Date().timeIntervalSince(runStarted),
                            done, Date().timeIntervalSince(started))
                        FileHandle.standardError.write(Data(message.utf8))
                    }
                }
            }
            try ScorecardReport.write(rowsDirectory: rows, to: out, order: Self.targets.map(\.id))
            let message = String(format: "scorecard: %d runs in %.0f s\n", done, Date().timeIntervalSince(started))
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
#endif
