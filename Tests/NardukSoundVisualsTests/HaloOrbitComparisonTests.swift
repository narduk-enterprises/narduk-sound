#if canImport(AVFoundation) && canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukMusicRender
    import Testing

    @testable import NardukSoundVisuals

    /// Opt-in, silent evidence generation through the same exporter Beat Blaster uses. No audio device is opened.
    /// HALO_ORBIT_OUT=<new directory> swift test --filter HaloOrbitComparisonTests
    @MainActor @Suite(.serialized) struct HaloOrbitComparisonTests {
        nonisolated static let enabled = ProcessInfo.processInfo.environment["HALO_ORBIT_OUT"] != nil
        static let seconds = 24.0
        static let look = SoundPaletteLook(preset: .ocean)

        struct Song {
            let audio: RenderedAudio
            let timeline: SoundVisualTimeline
        }

        /// An original 120 BPM synth phrase. Only procedural kick, snare, hats, sub and electric piano are used;
        /// no vocal or recorded instrument bank, external audio, microphone, paid service or download.
        static func song() -> Song {
            let settings = SongSettings(bpm: 120, genre: .house, seed: 7, variety: 0, vocals: false)
            let renderer = OfflineRenderer(settings: settings, playsConductor: false)
            let pitches = [57, 60, 64, 67, 64, 60, 55, 60]
            var notes: [ScheduledNote] = []
            for step in 0..<176 {
                let time = Double(step) * settings.secondsPerStep
                let velocity = time < 4 ? 0.48 : (time < 12 ? 0.64 : (time < 20 ? 0.82 : 0.4))
                if step % 4 == 0 {
                    notes.append(ScheduledNote(step: step, instrument: .kick, velocity: velocity))
                    notes.append(
                        ScheduledNote(
                            step: step + 2, instrument: .sub, velocity: velocity * 0.65,
                            params: NoteParams(pitch: 45 + (step / 32 % 2) * 5, lengthSteps: 2)))
                }
                if time >= 4, step % 8 == 4 {
                    notes.append(ScheduledNote(step: step, instrument: .snare, velocity: velocity * 0.48))
                }
                if time >= 6, step % 2 == 1 {
                    notes.append(ScheduledNote(step: step, instrument: .hat, velocity: velocity * 0.28))
                }
                if step % 4 == 0 || (time >= 12 && time < 20 && step % 4 == 2) {
                    notes.append(
                        ScheduledNote(
                            step: step, instrument: .keys, velocity: velocity * 0.55,
                            params: NoteParams(
                                pitch: pitches[step / 2 % pitches.count], lengthSteps: 3, voice: 2,
                                pan: step % 8 == 0 ? -0.25 : 0.25)))
                }
            }
            renderer.schedule(notes)
            var left: [Float] = []
            var right: [Float] = []
            var hits = HitCounters()
            var timeline = SoundVisualTimeline()
            timeline.looks = [.init(time: 0, value: look)]
            for tick in 0..<Int(seconds * 60) {
                let output = renderer.advance()
                left += output.left
                right += output.right
                for instrument in renderer.takeHits() { hits.record(instrument) }
                let time = Double(tick + 1) / 60
                let section: SongSection = time < 4 ? .intro : (time < 12 ? .build : (time < 20 ? .drop : .breakdown))
                let energy: Float =
                    time < 4 ? 0.18 : (time < 12 ? Float(0.3 + (time - 4) * 0.055) : (time < 20 ? 0.8 : 0.22))
                timeline.samples.append(
                    .init(
                        time: time,
                        music: MusicContext(
                            hitCounts: hits, step: Int(time / settings.secondsPerStep), section: section,
                            energy: energy, isRunning: time < 22, secondsPerStep: settings.secondsPerStep)))
            }
            return Song(
                audio: RenderedAudio(sampleRate: renderer.sampleRate, left: left, right: right), timeline: timeline)
        }

        @Test(.enabled(if: enabled)) func exportsMatchedNativePresetsAndMeasuresGPU() async throws {
            let path = try #require(ProcessInfo.processInfo.environment["HALO_ORBIT_OUT"])
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Require an empty destination so rerunning the review never overwrites a previous master.
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("before-native.mp4").path))
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("before-native.mp4").path)
            else {
                throw ComparisonError.existingOutput
            }
            let song = Self.song()
            #expect(song.audio == Self.song().audio, "original synth audio must be deterministic")
            let audioURL = directory.appendingPathComponent("original-synth.m4a")
            try AudioFileWriter.writeWAV(song.audio, to: directory.appendingPathComponent("original-synth.wav"))
            try AudioFileWriter.writeM4A(song.audio, to: audioURL, bitRate: 256_000)
            try song.timeline.encoded().write(to: directory.appendingPathComponent("original-synth.lights"))
            let settings = SoundVideoSettings(
                width: 960, height: 540, framesPerSecond: 30, codec: .h264, bitsPerSecond: 6_000_000,
                gpuBudgetMilliseconds: nil)
            var records: [[String: Any]] = []
            for (name, kind) in [("before", IntenseKind.halo), ("after", IntenseKind.haloOrbit)] {
                let output = directory.appendingPathComponent("\(name)-native.mp4")
                let report = try await SoundVideoExporter().export(
                    audio: audioURL, timeline: song.timeline, to: output, settings: settings,
                    fallbackLight: .intense(kind), look: Self.look)
                #expect(report.lowestRenderScale == 1, "comparison must use identical native resolution")
                let gpu = try Self.measure(kind, audio: audioURL, timeline: song.timeline, directory: directory)
                records.append([
                    "preset": kind.id, "frames": report.frames, "seconds": report.seconds,
                    "wallSeconds": report.wallSeconds, "bytes": report.bytes, "renderScale": report.lowestRenderScale,
                    "gpu": gpu,
                ])
                print(
                    "HALO \(name) frames=\(report.frames) wall_s=\(report.wallSeconds) scale=\(report.lowestRenderScale)"
                )
            }
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "audioFingerprint": String(song.audio.fingerprint), "audioSeed": 7,
                    "visualSeed": "SoundVisualState default 0x9E3779B97F4A7C15", "width": 960, "height": 540,
                    "fps": 30, "look": "ocean", "platform": "macOS desktop; tvOS untested", "exports": records,
                ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("native-report.json"))
        }

        enum ComparisonError: Error { case existingOutput }

        /// Render-only command-buffer GPU durations, separately from codec, disk and CPU analysis costs.
        /// Both sequences replay the same AAC and timeline. First 30 frames are warm-up, then 690 across intro, build, drop and settle are measured.
        static func measure(
            _ kind: IntenseKind, audio: URL, timeline: SoundVisualTimeline, directory: URL
        ) throws -> [String: Any] {
            let painter = try #require(SoundVideoPainter(), "native Metal renderer unavailable")
            let scene = SoundVideoScene(
                source: try PCMReader(url: audio), timeline: timeline, fallbackLight: .intense(kind),
                lights: { _ in nil }, look: look, calm: false)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 960, height: 540, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            let texture = try #require(painter.device.makeTexture(descriptor: descriptor))
            var times: [Double] = []
            var syncRows = ["videoSeconds,stateKick,timelineKickCount"]
            for index in 0..<720 {
                let time = Double(index) / 30
                _ = try scene.advance(to: time)
                let count = timeline.music(at: time)?.hitCounts[.kick] ?? 0
                syncRows.append("\(time),\(scene.state.kick),\(count)")
                let buffer = try #require(painter.queue.makeCommandBuffer())
                #expect(painter.encode(.intense(kind), buffer: buffer, target: texture, state: scene.state))
                buffer.commit()
                buffer.waitUntilCompleted()
                #expect(buffer.status == .completed)
                if index >= 30 { times.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
            }
            try syncRows.joined(separator: "\n").write(
                to: directory.appendingPathComponent("\(kind.id)-sync.csv"), atomically: true, encoding: .utf8)
            times.sort()
            #expect(times.count == 690 && times.allSatisfy { $0 > 0 && $0.isFinite })
            return [
                "device": painter.device.name, "samples": times.count,
                "medianMilliseconds": times[times.count / 2],
                "p95Milliseconds": times[Int(Double(times.count - 1) * 0.95)],
                "maxMilliseconds": times[times.count - 1],
                "meanMilliseconds": times.reduce(0, +) / Double(times.count),
            ]
        }
    }
#endif
