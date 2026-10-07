#if canImport(AVFoundation) && canImport(Metal)
    import Foundation
    import NardukMusicCore
    import NardukMusicRender
    import NardukSoundAnalysis

    @testable import NardukSoundVisuals

    /// A real song for the video tests: rendered offline, saved as AAC the way the live recorder saves it, with the
    /// timeline a recording would have kept beside it, and the inputs the live screen would have drawn from at every
    /// 60 Hz tick (the exact samples and music, no AAC), to compare the offline picture against.
    struct VideoSongFixture {
        let audio: URL
        let timeline: SoundVisualTimeline
        /// What the live screen saw at each tick: the time (seconds into the recording) and the input.
        let live: [(time: Double, input: SoundVisualInput)]
        let seconds: Double

        static func make(
            seconds: Double, genre: Genre = .house, light: String = "test-light", directory: URL
        ) throws -> VideoSongFixture {
            var settings = SongSettings()
            settings.genre = genre
            let renderer = OfflineRenderer(settings: settings)
            let ticks = Int(seconds * OfflineRenderer.tickRate)
            var left: [Float] = []
            var right: [Float] = []
            left.reserveCapacity(ticks * renderer.framesPerTick)
            right.reserveCapacity(ticks * renderer.framesPerTick)
            let analyzer = SoundAnalyzer(sampleRate: renderer.sampleRate)
            var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
            var hits = HitCounters()
            var recorder = SoundVisualTimelineRecorder()
            recorder.light(light, at: 0)
            var live: [(Double, SoundVisualInput)] = []
            for tick in 0..<ticks {
                let (l, r) = renderer.advance()
                left += l
                right += r
                for instrument in renderer.takeHits() { hits.record(instrument) }
                let time = Double(tick + 1) / OfflineRenderer.tickRate
                let snapshot = renderer.snapshot
                let song = renderer.settings
                let music = MusicContext(
                    hitCounts: hits, step: snapshot.step, section: snapshot.section, energy: Float(snapshot.energy),
                    wobblePhase: Float((Double(snapshot.step) / 4).truncatingRemainder(dividingBy: 1)),
                    wobbleCutoff: 0.5, isRunning: true, secondsPerStep: song.secondsPerStep,
                    stepsPerBar: song.stepsPerBar, stepsPerPhrase: song.stepsPerPhrase,
                    phraseProgress: Float(snapshot.phraseProgress(song)),
                    buildThreshold: Float(snapshot.buildThreshold),
                    dropThreshold: Float(snapshot.dropThreshold), dropQueued: snapshot.dropQueued)
                window.withUnsafeMutableBufferPointer { renderer.copyRecentSamples(into: $0) }
                let frame = window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
                live.append((time, SoundVisualInput(frame: frame, music: music)))
                recorder.record(music, at: time)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("song-\(UUID().uuidString).m4a")
            try AudioFileWriter.writeM4A(
                RenderedAudio(sampleRate: renderer.sampleRate, left: left, right: right), to: url, bitRate: 256_000)
            return VideoSongFixture(audio: url, timeline: recorder.timeline, live: live, seconds: seconds)
        }
    }
#endif
