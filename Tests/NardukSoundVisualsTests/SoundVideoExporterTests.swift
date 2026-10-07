#if canImport(AVFoundation) && canImport(Metal)
    import AVFoundation
    import Foundation
    import Metal
    import NardukMusicCore
    import Testing

    @testable import NardukSoundVisuals

    /// The video share path: a recorded song (AAC plus its timeline) becomes an `.mp4` with the song's audio and the
    /// lights drawn again offline.
    @MainActor @Suite struct SoundVideoExporterTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil
        static let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SoundVideoExporterTests", isDirectory: true)

        @Test(.enabled(if: hasMetal)) func exportsAPlayableVideoWithTheSongAndItsLights() async throws {
            let song = try VideoSongFixture.make(seconds: 3, directory: Self.directory)
            let output = Self.directory.appendingPathComponent("song.mp4")
            var seen: [Double] = []
            let report = try await SoundVideoExporter().export(
                audio: song.audio, timeline: song.timeline, to: output,
                settings: SoundVideoSettings(width: 180, height: 320, framesPerSecond: 30),
                fallbackLight: .tunnel, lights: { $0 == "test-light" ? .intense(.liquidSplash) : nil },
                progress: { seen.append($0) })

            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - song.seconds) < 0.15, "video lasts \(duration) s for a \(song.seconds) s song")
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            #expect(videoTracks.count == 1)
            #expect(audioTracks.count == 1)
            if let video = videoTracks.first {
                let size = try await video.load(.naturalSize)
                #expect(size == CGSize(width: 180, height: 320))
                let videoSeconds = try await video.load(.timeRange).duration.seconds
                #expect(abs(videoSeconds - song.seconds) < 0.1)
            }
            if let audio = audioTracks.first {
                let audioSeconds = try await audio.load(.timeRange).duration.seconds
                #expect(abs(audioSeconds - song.seconds) < 0.15)
            }
            #expect(report.frames == 90)
            #expect(report.bytes > 0)
            #expect(seen.last == 1)

            let luma = try await Self.meanLuma(of: output, at: 2)
            #expect(luma > 0.02, "the lights are drawn (mean luma \(luma))")
        }

        @Test(.enabled(if: hasMetal)) func aSongWithoutATimelineStillGetsLights() async throws {
            let song = try VideoSongFixture.make(seconds: 2, directory: Self.directory)
            let output = Self.directory.appendingPathComponent("old-song.mp4")
            try await SoundVideoExporter().export(
                audio: song.audio, timeline: nil, to: output,
                settings: SoundVideoSettings(width: 160, height: 160, framesPerSecond: 30),
                fallbackLight: .shaderPack(.plasma))
            let luma = try await Self.meanLuma(of: output, at: 1.5)
            #expect(luma > 0.02, "mean luma \(luma)")
        }

        @Test(.enabled(if: hasMetal)) func cancellingStopsAndLeavesNoFile() async throws {
            let song = try VideoSongFixture.make(seconds: 4, directory: Self.directory)
            let output = Self.directory.appendingPathComponent("cancelled.mp4")
            let task = Task { @MainActor in
                try await SoundVideoExporter().export(
                    audio: song.audio, timeline: song.timeline, to: output,
                    settings: SoundVideoSettings(width: 160, height: 160), fallbackLight: .tunnel,
                    progress: { if $0 > 0.2 { withUnsafeCurrentTask { $0?.cancel() } } })
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }

        @Test(.enabled(if: hasMetal)) func aLightOverTheGPUBudgetIsDrawnSmallerAndStillFillsTheFrame() async throws {
            let song = try VideoSongFixture.make(seconds: 2, directory: Self.directory)
            let output = Self.directory.appendingPathComponent("scaled.mp4")
            let report = try await SoundVideoExporter().export(
                audio: song.audio, timeline: song.timeline, to: output,
                settings: SoundVideoSettings(width: 180, height: 320, gpuBudgetMilliseconds: 0.000_1),
                fallbackLight: .intense(.liquidSplash))
            #expect(report.lowestRenderScale == SoundVideoScaler.lowest)
            let size = try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            #expect(size == CGSize(width: 180, height: 320), "the video keeps its size")
            let luma = try await Self.meanLuma(of: output, at: 1.5)
            #expect(luma > 0.02, "the upscaled frame is drawn (mean luma \(luma))")
        }

        @Test(.enabled(if: hasMetal)) func theScalerSettlesEachLightFromItsMeasuredFrames() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let scaler = SoundVideoScaler(device: device, width: 720, height: 1280, budgetMilliseconds: 20)
            for _ in 0..<SoundVideoScaler.measuredFrames {
                #expect(scaler.scale(for: .intense(.jellyfish)) == 1, "full size while measuring")
                scaler.record(.intense(.jellyfish), milliseconds: 45)
                scaler.record(.tunnel, milliseconds: 6)
            }
            // sqrt(20 / 45) = 0.667, rounded down to a twentieth.
            #expect(scaler.scale(for: .intense(.jellyfish)) == 0.65)
            #expect(scaler.scale(for: .tunnel) == 1)
            #expect(scaler.lowestScale == 0.65)
            let small = try #require(scaler.texture(scale: 0.65))
            #expect(small.width == 468 && small.height == 832)

            let unlimited = SoundVideoScaler(device: device, width: 720, height: 1280, budgetMilliseconds: nil)
            for _ in 0..<20 { unlimited.record(.intense(.jellyfish), milliseconds: 500) }
            #expect(unlimited.scale(for: .intense(.jellyfish)) == 1, "no budget, no scaling")
        }

        /// The mean luma (0 ... 1) of the video frame at `seconds`.
        static func meanLuma(of url: URL, at seconds: Double) async throws -> Double {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard
                    let context = CGContext(
                        data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return 0 }
            var sum = 0
            for i in stride(from: 0, to: pixels.count, by: 4) {
                sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
            }
            return Double(sum) / Double(width * height * 3 * 255)
        }
    }

    /// The timeline's file format and recorder.
    @Suite struct SoundVisualTimelineTests {
        @Test func roundTripsThroughItsFileFormat() throws {
            var recorder = SoundVisualTimelineRecorder()
            var hits = HitCounters()
            for i in 0..<300 {
                if i % 8 == 0 { hits.record(.kick) }
                let music = MusicContext(
                    hitCounts: hits, step: i / 2, section: i > 150 ? .drop : .build, energy: Float(i) / 300,
                    isRunning: true, heldNotes: NoteSet([60, 64, 67]), keyPitchClass: 9, keyIsMinor: true)
                recorder.record(music, at: Double(i) / 60)
                recorder.record(music, at: Double(i) / 60 + 0.004)  // a second poll in the same frame is dropped
            }
            recorder.light("tunnel", at: 0)
            recorder.light("tunnel", at: 1)
            recorder.light("shader-plasma", at: 2)
            recorder.look(.neutral, at: 0)
            recorder.look(SoundPaletteLook(preset: .ocean), at: 3)
            recorder.calm(true, at: 4)
            let timeline = recorder.timeline
            #expect(timeline.samples.count == 300, "every sample of a 60 Hz feed")
            #expect(timeline.lights.count == 2, "a repeat is dropped")
            let decoded = try SoundVisualTimeline(decoding: timeline.encoded())
            #expect(decoded == timeline)
        }

        @Test func answersWhatWasShowingAtATime() {
            var recorder = SoundVisualTimelineRecorder()
            recorder.light("a", at: 1)
            recorder.light("b", at: 5)
            recorder.record(MusicContext(step: 4), at: 1)
            recorder.record(MusicContext(step: 8), at: 2)
            let timeline = recorder.timeline
            #expect(SoundVisualTimeline.value(of: timeline.lights, at: 0) == "a", "before the first change: the first")
            #expect(SoundVisualTimeline.value(of: timeline.lights, at: 4.9) == "a")
            #expect(SoundVisualTimeline.value(of: timeline.lights, at: 5) == "b")
            #expect(timeline.music(at: 0.5) == nil)
            #expect(timeline.music(at: 1.5)?.step == 4)
            #expect(timeline.music(at: 2.4)?.step == 8)
            #expect(timeline.music(at: 3) == nil, "a gap longer than half a second falls back to the audio alone")
        }

        @Test func rejectsAFileThatIsNotATimeline() {
            #expect(throws: SoundVisualTimeline.FormatError.notATimeline) {
                try SoundVisualTimeline(decoding: Data("hello".utf8))
            }
        }

        @Test func aMinuteIsSmall() throws {
            var recorder = SoundVisualTimelineRecorder()
            var hits = HitCounters()
            for i in 0..<(60 * 60) {
                if i % 7 == 0 { hits.record(.kick) }
                if i % 13 == 0 { hits.record(.snare) }
                recorder.record(
                    MusicContext(
                        hitCounts: hits, step: i / 4, energy: Float(i % 97) / 97, wobblePhase: Float(i % 31) / 31,
                        isRunning: true, phraseProgress: Float(i % 512) / 512),
                    at: Double(i) / 60)
            }
            let bytes = recorder.timeline.encoded().count
            #expect(bytes < 200_000, "a minute of timeline is \(bytes) bytes")
        }
    }
#endif
