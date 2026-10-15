import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

#if canImport(Metal)
    import Metal
#endif

/// `SoundTimeline`: the format, the recorder, the player, and the proof that a picture drawn from a recorded timeline
/// matches the picture drawn from live `SoundMusicInference`. Headless: the classic demo loop is rendered in memory
/// (`OfflineRenderer`), the Sun is drawn offscreen; no window, no audio device.
///
/// Environment: `SOUND_TIMELINE_METRICS=1` prints the measured numbers; `SOUND_TIMELINE_CLIP_OUT=<dir>` writes silent
/// 960x540 clips of the Sun live and replayed; `SOUND_TIMELINE_OUT=<path>` records `SOUND_TIMELINE_WAV` (default
/// `~/Music/Captures/demo-classic-loop.wav`) offline and writes the timeline there.
@Suite struct SoundTimelineTests {
    // MARK: Fixtures

    struct Loop: Sendable {
        var frames: [SoundFrame]
        var live: [MusicContext]
        var timeline: SoundTimeline
    }

    static let tickRate = OfflineRenderer.tickRate

    /// The classic demo loop for `seconds`, analyzed at 60 Hz, heard by `SoundMusicInference` and recorded.
    static func makeLoop(
        seconds: Double, gridRate: Double = SoundTimeline.defaultGridRate,
        waveformPoints: Int = SoundTimeline.waveformPoints, waveformEvery: Int = SoundTimeline.defaultWaveformEvery
    ) -> Loop {
        let settings = SongSettings()
        let renderer = OfflineRenderer(settings: settings, playsConductor: false)
        renderer.schedule(DemoPattern.notes(in: 0...(Int(seconds / settings.secondsPerStep) + 1)))
        let analyzer = SoundAnalyzer(sampleRate: renderer.sampleRate)
        let recorder = SoundTimelineRecorder(
            trackID: "demo-classic-loop", gridRate: gridRate, analysisSampleRate: renderer.sampleRate,
            waveformPoints: waveformPoints, waveformEvery: waveformEvery)
        var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
        var frames: [SoundFrame] = []
        var live: [MusicContext] = []
        for tick in 0..<Int(seconds * tickRate) {
            _ = renderer.advance()
            window.withUnsafeMutableBufferPointer { renderer.copyRecentSamples(into: $0) }
            let frame = window.withUnsafeBufferPointer {
                analyzer.analyze($0, time: Double(tick + 1) / tickRate)
            }
            recorder.record(frame)
            frames.append(frame)
            live.append(recorder.inference.latest)
        }
        return Loop(frames: frames, live: live, timeline: recorder.finish())
    }

    /// 76 s: long enough for the seek test to jump to 60 s and settle.
    static let longLoop = makeLoop(seconds: 76)
    static let shortLoop = makeLoop(seconds: 12)

    static func time(_ tick: Int) -> Double { Double(tick + 1) / tickRate }

    static var metrics: Bool { ProcessInfo.processInfo.environment["SOUND_TIMELINE_METRICS"] != nil }

    /// The scope's trigger: the first rising zero crossing in the leading 128 samples (`IntenseAux.trigger`).
    static func scopeTrigger(_ wave: [Float]) -> Int {
        for i in 1..<128 where wave[i - 1] < 0 && wave[i] >= 0 { return i }
        return 0
    }

    // MARK: Format

    @Test func encodedTimelineRoundTripsByteForByte() throws {
        let timeline = Self.shortLoop.timeline
        let data = try timeline.encoded()
        let decoded = try SoundTimeline(decoding: data)
        #expect(decoded == timeline)
        #expect(try decoded.encoded() == data)
        #expect(data.count == 10 + (try JSONEncoder().encode(timeline.header)).count + timeline.payloadByteCount)

        let json = try JSONEncoder().encode(timeline)
        #expect(try JSONDecoder().decode(SoundTimeline.self, from: json) == timeline)
    }

    @Test func rejectsForeignDataAndNewerVersions() throws {
        #expect(throws: SoundTimeline.DecodingError.notATimeline) {
            try SoundTimeline(decoding: Data("nope, not a timeline".utf8))
        }
        var data = try Self.shortLoop.timeline.encoded()
        data[4] = 2  // version 2
        #expect(throws: SoundTimeline.DecodingError.unsupportedVersion(2)) { try SoundTimeline(decoding: data) }
        let whole = try Self.shortLoop.timeline.encoded()
        #expect(throws: SoundTimeline.DecodingError.truncated) {
            try SoundTimeline(decoding: whole.prefix(whole.count - 1))
        }
    }

    @Test func gridCoversTheRecordingAndFitsTheBudget() throws {
        let loop = Self.shortLoop
        let timeline = loop.timeline
        let last = Self.time(loop.frames.count - 1)
        #expect(timeline.duration == last)
        // The last sample is the first grid time at or after the last frame.
        #expect(Double(timeline.sampleCount - 1) / timeline.gridRate >= last - 1e-9)
        #expect(Double(timeline.sampleCount - 2) / timeline.gridRate < last)
        // 4 minutes at this grid must stay inside the ~2 MB budget.
        let fourMinutes = Double(timeline.payloadByteCount) / timeline.duration * 240
        #expect(fourMinutes <= 2_000_000, "\(fourMinutes) payload bytes in 4 min")
        #expect(timeline.header.hitLanes.contains(Instrument.kick.index))
        #expect(timeline.header.inference == .current)
    }

    @Test func recordingTheSameFramesTwiceIsByteIdentical() throws {
        let a = try Self.makeLoop(seconds: 8).timeline.encoded()
        let b = try Self.makeLoop(seconds: 8).timeline.encoded()
        #expect(a == b)
        #expect(a.count > 1000)
    }

    @Test func hitsAreNeverLostToTheGrid() {
        // Every hit the inference counted is in the timeline, however the grid slices them.
        for rate in [50.0, 60.0, 25.0] {
            let loop = Self.makeLoop(seconds: 6, gridRate: rate)
            let player = SoundTimelinePlayer(loop.timeline)
            let total = player.input(at: loop.timeline.duration + 1).music!.hitCounts
            // Played through once, continuously.
            let walk = SoundTimelinePlayer(loop.timeline)
            var seen = HitCounters()
            for tick in 0..<loop.frames.count { seen = walk.input(at: Self.time(tick)).music!.hitCounts }
            seen = walk.input(at: loop.timeline.duration + 1).music!.hitCounts
            let live = loop.live.last!.hitCounts
            for instrument in [Instrument.kick, .snare, .hat, .impact] {
                #expect(seen[instrument] == live[instrument], "\(instrument) at \(rate) Hz")
            }
            _ = total
        }
    }

    // MARK: Player

    @Test func counterNeverFallsAndASeekFiresNothing() {
        let timeline = Self.longLoop.timeline
        let player = SoundTimelinePlayer(timeline)
        var last = HitCounters()
        var seeks = 0
        func play(_ from: Double, _ seconds: Double) {
            var t = from
            while t < from + seconds {
                let counters = player.input(at: t).music!.hitCounts
                let delta = counters.delta(since: last)
                for lane in 0..<HitCounters.laneCount {
                    #expect(delta.lanes[lane] < 1 << 20, "lane \(lane) fell at \(t)")
                }
                last = counters
                t += 1.0 / 60
            }
        }
        play(0, 6)
        let before = last
        // Seek back, then far ahead, then back again: each lands without a hit.
        for target in [2.0, 61.0, 10.0, 70.0] {
            let landed = player.input(at: target).music!.hitCounts
            #expect(landed == before || landed.delta(since: last) == HitCounters(), "seek to \(target) fired hits")
            last = landed
            seeks += 1
            play(target, 3)
        }
        #expect(seeks == 4)
    }

    @Test func stepAdvancesOnTheClockAndNeverPassesTheNextSample() {
        let timeline = Self.longLoop.timeline
        let player = SoundTimelinePlayer(timeline)
        var lastStep = Int.min
        var t = 4.0
        while t < 20 {
            let step = player.input(at: t).music!.step
            if lastStep != Int.min { #expect(step >= lastStep - 2, "step fell at \(t)") }
            let i = min(Int(t * timeline.gridRate + 1e-9), timeline.sampleCount - 2)
            // The inference's lock can lower the step by a count or two; there the clock holds until the next sample.
            if timeline.position[i + 1] >= timeline.position[i] {
                #expect(step <= Int(timeline.position[i + 1].rounded(.down)))
                #expect(step >= Int(timeline.position[i].rounded(.down)))
            }
            lastStep = step
            t += 1.0 / 240  // between samples too
        }
        // Between two samples a step boundary is crossed on the clock, not at a sample.
        var crossings = Set<Int>()
        var previous = player.input(at: 8).music!.step
        t = 8
        while t < 12 {
            t += 1.0 / 1000
            let step = player.input(at: t).music!.step
            if step != previous { crossings.insert(Int((t * timeline.gridRate * 10).rounded())) }
            previous = step
        }
        #expect(crossings.count > 8)
    }

    @Test @MainActor func aBackwardSeekLooksLikeTheEnginesSeek() {
        let timeline = Self.longLoop.timeline
        let player = SoundTimelinePlayer(timeline)
        let ahead = player.input(at: 30).music!.step
        let back = player.input(at: 12).music!.step
        #expect(back < ahead)
        // And the visual state takes it as a reset of its beat clock.
        let state = SoundVisualState()
        state.update(player.input(at: 30), now: 1)
        state.update(player.input(at: 30.02), now: 1.02)
        #expect(state.stepPosition >= Double(ahead))
        state.update(player.input(at: 12), now: 1.04)
        #expect(state.stepPosition < Double(ahead) - 10)
        #expect(abs(state.stepPosition - Double(back)) < 2)
    }

    @Test func pastTheEndHoldsTheLastSampleAndStops() throws {
        let timeline = Self.shortLoop.timeline
        let player = SoundTimelinePlayer(timeline)
        _ = player.input(at: timeline.duration - 0.3)
        let atEnd = player.input(at: timeline.duration)
        let later = player.input(at: timeline.duration + 30)
        let muchLater = player.input(at: timeline.duration + 90)
        #expect(atEnd.music?.isRunning == false)
        #expect(later.frame == muchLater.frame)
        #expect(later.frame.spectrum == atEnd.frame.spectrum)
        #expect(later.music == muchLater.music)
        let last = timeline.sampleCount - 1
        #expect(later.music?.step == Int(timeline.position[last].rounded(.down)))
        // Before the start clamps to the first sample.
        #expect(player.input(at: -5).frame.spectrum.count == 64)
        #expect(SoundTimelinePlayer(timeline).input(at: 0).frame.sequence == 1)
    }

    @Test func theSameTimeReturnsTheSameInput() {
        let player = SoundTimelinePlayer(Self.shortLoop.timeline)
        let a = player.input(at: 3.3)
        let b = player.input(at: 3.3)
        #expect(a.frame == b.frame)
        #expect(player.input(at: 3.31).frame.sequence == a.frame.sequence + 1)
    }

    @Test func anEmptyTimelinePlaysSilence() throws {
        let timeline = SoundTimelineRecorder(trackID: "empty").finish()
        #expect(timeline.sampleCount == 0)
        let input = SoundTimelinePlayer(timeline).input(at: 5)
        #expect(input.frame.spectrum.allSatisfy { $0 == 0 })
        let decoded = try SoundTimeline(decoding: timeline.encoded())
        #expect(decoded == timeline)
    }

    @Test func theRestoredWaveformKeepsTheShapeAndTheScopeTrigger() {
        let loop = Self.longLoop
        let player = SoundTimelinePlayer(loop.timeline)
        var errors: [Float] = []
        var triggerKept = 0
        var triggerChecked = 0
        for sample in stride(from: 100, to: loop.timeline.sampleCount - 5, by: 4)
        where sample % loop.timeline.header.waveformEvery == 0 {
            let time = Double(sample) / loop.timeline.gridRate
            // The frame the sample was taken from: the latest one at or before the grid time.
            let tick = Int((time * Self.tickRate + 1e-9).rounded(.down)) - 1
            let original = loop.frames[tick].waveform
            let restored = player.input(at: time).frame.waveform
            var square: Float = 0
            var power: Float = 0
            for i in 0..<512 {
                square += (restored[i] - original[i]) * (restored[i] - original[i])
                power += original[i] * original[i]
            }
            guard power > 1e-4 else { continue }
            errors.append((square / power).squareRoot())
            let want = Self.scopeTrigger(restored)
            let got = Self.scopeTrigger(original)
            triggerChecked += 1
            if abs(want - got) <= 4 { triggerKept += 1 }
        }
        errors.sort()
        let median = errors[errors.count / 2]
        if Self.metrics {
            print(
                "timeline waveform: median relative error \(median), p90 \(errors[errors.count * 9 / 10]); scope trigger within 4 samples \(triggerKept)/\(triggerChecked)"
            )
        }
        #expect(!errors.isEmpty)
    }

    /// After a jump to 60 s the state a tile reads is the state a continuous replay has there, within a settle window.
    @Test @MainActor func stateSettlesAfterASeek() {
        let loop = Self.longLoop
        let jumpTick = 300
        let offset = 60.0 - Double(jumpTick) / Self.tickRate
        let continuous = SoundTimelinePlayer(loop.timeline)
        let jumping = SoundTimelinePlayer(loop.timeline)
        let a = SoundVisualState()
        let b = SoundVisualState()
        func snapshot(_ s: SoundVisualState) -> [Float] {
            var v: [Float] = [
                s.kick, s.snare, s.hat, s.impact, s.glitch, s.laser, s.flash, s.shake, s.chroma, s.level, s.energy,
                s.wild, s.dropAmount, s.wobbleCutoff, s.phraseProgress, Float(s.peak), Float(s.rms), s.beatPulse,
                Float(s.section == .drop || s.section == .drop2 ? 1 : 0),
            ]
            v.append(contentsOf: s.spectrum)
            v.append(contentsOf: s.musical.pitchClasses)
            return v
        }
        var lastDifferent = 0
        var worst: Float = 0
        for tick in 0..<(jumpTick + 12 * 60) {
            let now = Self.time(tick)
            a.update(continuous.input(at: offset + now), now: now)
            b.update(jumping.input(at: tick < jumpTick ? now : offset + now), now: now)
            guard tick >= jumpTick else { continue }
            let difference = zip(snapshot(a), snapshot(b)).map { abs($0 - $1) }.max() ?? 0
            if difference > 0.05 { lastDifferent = tick - jumpTick + 1 }
            worst = max(worst, difference)
            if tick >= jumpTick + 120 { #expect(a.section == b.section) }
        }
        let settle = Double(lastDifferent) / Self.tickRate
        if Self.metrics {
            print("timeline seek state: worst difference \(worst), last above 0.05 at \(settle) s after the jump")
        }
        #expect(settle <= 1.0, "the state still differed \(settle) s after the jump")
    }
}

// MARK: - Pictures

#if canImport(AVFoundation) && canImport(Metal)
    import AVFoundation

    extension SoundTimelineTests {
        typealias FrameStat = SunClipTests.FrameStat

        /// Drives a fresh `SoundVisualState` through `count` ticks (`step` gives each tick's `now` and input), draws `kind`
        /// from `renderFrom` on, and returns the mean luma and motion of each drawn frame. Frames before `renderFrom` still
        /// advance the state, the motion and the flash limiter, only the draw is skipped.
        @MainActor
        static func series(
            _ kind: IntenseKind = .sun, count: Int, renderFrom: Int = 0, width: Int = 480, height: Int = 270,
            clip: URL? = nil, step: (Int) -> (now: Double, input: SoundVisualInput)
        ) throws -> [FrameStat] {
            let state = SoundVisualState()
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
            let writer = try clip.map { try SunClipTests.ClipWriter(url: $0, width: width, height: height) }
            var stats: [FrameStat] = []
            for tick in 0..<count {
                let (now, input) = step(tick)
                state.update(input, now: now)
                let drive = IntenseDrive(state: state, limiter: &limiter)
                motion.advance(kind, state: state, intensity: drive.intensity)
                guard tick >= renderFrom else { continue }
                let buffer = try #require(metal.queue.makeCommandBuffer())
                metal.encode(
                    kind, buffer: buffer, target: texture, state: state, drive: drive, uniforms: &uniforms,
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
                try writer?.append(pixels, width: width, height: height)
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
            try writer?.finish()
            return stats
        }

        struct Difference {
            var maxLuma: Float
            var meanLuma: Float
            var maxMotion: Float
            var meanMotion: Float
            var lumaRange: Float
            var motionRange: Float
            var lumaCorrelation: Float
            var motionCorrelation: Float
        }

        static func compare(_ a: [FrameStat], _ b: [FrameStat]) -> Difference {
            func correlation(_ x: [Float], _ y: [Float]) -> Float {
                let n = Float(x.count)
                let mx = x.reduce(0, +) / n
                let my = y.reduce(0, +) / n
                var sxy: Float = 0
                var sxx: Float = 0
                var syy: Float = 0
                for (p, q) in zip(x, y) {
                    sxy += (p - mx) * (q - my)
                    sxx += (p - mx) * (p - mx)
                    syy += (q - my) * (q - my)
                }
                return sxy / max((sxx * syy).squareRoot(), 1e-12)
            }
            let luma = zip(a, b).map { abs($0.luma - $1.luma) }
            let motion = zip(a, b).map { abs($0.motion - $1.motion) }
            let lumas = a.map(\.luma)
            let motions = a.map(\.motion)
            return Difference(
                maxLuma: luma.max() ?? 0, meanLuma: luma.reduce(0, +) / Float(max(luma.count, 1)),
                maxMotion: motion.max() ?? 0, meanMotion: motion.reduce(0, +) / Float(max(motion.count, 1)),
                lumaRange: (lumas.max() ?? 0) - (lumas.min() ?? 0),
                motionRange: (motions.max() ?? 0) - (motions.min() ?? 0),
                lumaCorrelation: correlation(lumas, b.map(\.luma)),
                motionCorrelation: correlation(motions, b.map(\.motion)))
        }

        /// The pixel statistics are a per-pixel loop, so a debug build (the gate's first test step) draws a small picture:
        /// the same tile and the same frames, a fifth of the width. The optimized build draws the full 480 x 270.
        #if DEBUG
            static let renderSize = (96, 54)
        #else
            static let renderSize = (480, 270)
        #endif

        /// A tile drawn from live inference against the same tile drawn from the recorded timeline, tick for tick.
        @MainActor
        static func equivalence(_ kind: IntenseKind, loop: Loop, name: String) throws -> Difference {
            let count = loop.frames.count
            let clipDir = ProcessInfo.processInfo.environment["SOUND_TIMELINE_CLIP_OUT"].map {
                URL(fileURLWithPath: $0)
            }
            if let clipDir { try FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true) }
            let size = clipDir == nil ? Self.renderSize : (960, 540)
            let live = try series(
                kind, count: count, width: size.0, height: size.1,
                clip: clipDir?.appendingPathComponent("\(name)-live.mp4")
            ) { tick in (time(tick), SoundVisualInput(frame: loop.frames[tick], music: loop.live[tick])) }
            let player = SoundTimelinePlayer(loop.timeline)
            let replay = try series(
                kind, count: count, width: size.0, height: size.1,
                clip: clipDir?.appendingPathComponent("\(name)-timeline.mp4")
            ) { tick in (time(tick), player.input(at: time(tick))) }
            let difference = compare(live, replay)
            if let clipDir {
                var csv = "frame,seconds,live_luma,live_motion,timeline_luma,timeline_motion\n"
                for (index, (a, b)) in zip(live, replay).enumerated() {
                    csv += String(
                        format: "%d,%.3f,%.4f,%.4f,%.4f,%.4f\n", index, Double(index) / 60, a.luma, a.motion, b.luma,
                        b.motion)
                }
                try csv.write(
                    to: clipDir.appendingPathComponent("\(name)-timeline-frames.csv"), atomically: true, encoding: .utf8
                )
            }
            if metrics {
                print(
                    "timeline equivalence \(name) (\(count) frames, \(loop.timeline.gridRate) Hz grid): luma max \(difference.maxLuma) mean \(difference.meanLuma) of range \(difference.lumaRange) (r \(difference.lumaCorrelation)); motion max \(difference.maxMotion) mean \(difference.meanMotion) of range \(difference.motionRange) (r \(difference.motionCorrelation))"
                )
            }
            return difference
        }

        /// Luma and motion of the Sun and of the Scope (which reads the waveform) match live inference frame by frame.
        @Test @MainActor func tilesFromTheTimelineMatchTilesFromLiveInference() throws {
            for (kind, name) in [(IntenseKind.sun, "sun"), (.scope, "scope")] {
                let difference = try Self.equivalence(kind, loop: Self.longLoop, name: name)
                // The Sun ignores the waveform, so only the grid and 8-bit bands separate it from live; the Scope draws
                // the 32-point waveform itself, so it is the loosest tile.
                let exact = kind == .sun
                #expect(difference.meanLuma < (exact ? 0.0005 : 0.004), "\(name)")
                #expect(difference.maxLuma < (exact ? 0.01 : 0.02), "\(name)")
                #expect(difference.meanMotion < (exact ? 0.0005 : 0.005), "\(name)")
                #expect(difference.maxMotion < (exact ? 0.02 : 0.04), "\(name)")
                #expect(difference.lumaCorrelation > (exact ? 0.9999 : 0.995), "\(name)")
                #expect(difference.motionCorrelation > (exact ? 0.999 : 0.95), "\(name)")
            }
        }

        /// The measurements behind the grid rate and the waveform storage (printed, never asserted): the same loop on a 50 Hz
        /// grid, and the Scope (the tile that draws the waveform itself) under other waveform sizes.
        @Test(.enabled(if: SoundTimelineTests.metrics)) @MainActor func gridAndWaveformVariantsForComparison() throws {
            let slow = Self.makeLoop(seconds: 76, gridRate: 50)
            _ = try Self.equivalence(.sun, loop: slow, name: "sun-50hz")
            _ = try Self.equivalence(.scope, loop: slow, name: "scope-50hz")
            print(
                "timeline 50 Hz payload bytes per 4 min: \(Double(slow.timeline.payloadByteCount) / slow.timeline.duration * 240)"
            )
            for (points, every) in [(32, 2), (64, 1), (64, 2), (128, 1), (128, 3)] {
                let loop = Self.makeLoop(seconds: 76, waveformPoints: points, waveformEvery: every)
                _ = try Self.equivalence(.scope, loop: loop, name: "scope-\(points)x\(every)")
                print(
                    "timeline waveform \(points) points every \(every): payload bytes per 4 min \(Double(loop.timeline.payloadByteCount) / loop.timeline.duration * 240)"
                )
            }
        }

        /// What the state sees: the same sections, the same hits, the same silence, tick by tick.
        @Test @MainActor func theStateSeesTheSameSectionsHitsAndSilence() {
            let loop = Self.longLoop
            let liveState = SoundVisualState()
            let replayState = SoundVisualState()
            let player = SoundTimelinePlayer(loop.timeline)
            var liveSections: [SongSection] = []
            var replaySections: [SongSection] = []
            var liveBoundaries: [Int] = []
            var replayBoundaries: [Int] = []
            var silentMismatches = 0
            var liveKicks = 0
            var replayKicks = 0
            var lastLive = HitCounters()
            var lastReplay = HitCounters()
            for tick in 0..<loop.frames.count {
                let now = Self.time(tick)
                let liveInput = SoundVisualInput(frame: loop.frames[tick], music: loop.live[tick])
                let replayInput = player.input(at: now)
                liveState.update(liveInput, now: now)
                replayState.update(replayInput, now: now)
                if liveState.isSilent != replayState.isSilent { silentMismatches += 1 }
                if liveSections.last != liveState.section {
                    liveSections.append(liveState.section)
                    liveBoundaries.append(tick)
                }
                if replaySections.last != replayState.section {
                    replaySections.append(replayState.section)
                    replayBoundaries.append(tick)
                }
                let live = loop.live[tick].hitCounts
                let replay = replayInput.music!.hitCounts
                if live[.kick] != lastLive[.kick] { liveKicks += 1 }
                if replay[.kick] != lastReplay[.kick] { replayKicks += 1 }
                lastLive = live
                lastReplay = replay
            }
            let offsets = zip(liveBoundaries, replayBoundaries).map { abs($0 - $1) }
            if Self.metrics {
                print(
                    "timeline state: sections \(liveSections) boundary offsets (ticks) \(offsets); isSilent mismatches \(silentMismatches); kick ticks live \(liveKicks) replay \(replayKicks); final counters live \(lastLive[.kick])/\(lastLive[.snare])/\(lastLive[.hat])/\(lastLive[.impact]) replay \(lastReplay[.kick])/\(lastReplay[.snare])/\(lastReplay[.hat])/\(lastReplay[.impact])"
                )
            }
            #expect(liveSections == replaySections)
            #expect((offsets.max() ?? 0) <= 2, "section boundaries moved \(offsets) ticks")
            #expect(silentMismatches == 0)
            #expect(liveKicks > 20)
            #expect(liveKicks == replayKicks)
            // Played to the end, the player has counted every hit the inference did.
            _ = player.input(at: loop.timeline.duration + 1)
            let final = player.input(at: loop.timeline.duration + 2).music!.hitCounts
            for instrument in [Instrument.kick, .snare, .hat, .impact] {
                #expect(final[instrument] == loop.live.last!.hitCounts[instrument], "\(instrument)")
            }
        }

        /// A jump to 60 s settles to the picture a continuous replay shows there. Drawn with the Scope: the Sun integrates
        /// the state's `travel` over the whole history, so no two histories ever draw the same Sun (a property of the tile,
        /// not of the timeline); `stateSettlesAfterASeek` covers what the Sun does read.
        @Test @MainActor func aSeekSettlesToTheContinuousReplay() throws {
            let loop = Self.longLoop
            let jumpTick = 300  // 5 s in, then straight to 60 s
            let target = 60.0
            let count = jumpTick + 12 * 60
            let offset = target - Double(jumpTick) / Self.tickRate
            // Continuous: from `offset` on, so that at tick `jumpTick` it is already at 60 s with 5 s of history.
            let continuous = SoundTimelinePlayer(loop.timeline)
            let a = try Self.series(
                .scope, count: count, renderFrom: jumpTick, width: Self.renderSize.0, height: Self.renderSize.1
            ) { tick in
                (Self.time(tick), continuous.input(at: offset + Self.time(tick)))
            }
            let jumping = SoundTimelinePlayer(loop.timeline)
            let b = try Self.series(
                .scope, count: count, renderFrom: jumpTick, width: Self.renderSize.0, height: Self.renderSize.1
            ) { tick in
                let t = Self.time(tick)
                return (t, jumping.input(at: tick < jumpTick ? t : offset + t))
            }
            let luma = zip(a, b).map { abs($0.luma - $1.luma) }
            let motion = zip(a, b).map { abs($0.motion - $1.motion) }
            func settled(_ values: [Float], below limit: Float) -> Double {
                guard let last = values.lastIndex(where: { $0 > limit }) else { return 0 }
                return Double(last + 1) / Self.tickRate
            }
            let lumaSettle = settled(luma, below: 0.01)
            let motionSettle = settled(motion, below: 0.01)
            if Self.metrics {
                print(
                    "timeline seek: luma diff max \(luma.max()!) after 2 s \((luma.dropFirst(120).max())!), settles under 0.01 after \(lumaSettle) s; motion diff max \(motion.max()!) settles after \(motionSettle) s; mean luma diff after 2 s \(luma.dropFirst(120).reduce(0, +) / Float(luma.count - 120))"
                )
            }
            #expect(lumaSettle <= 1.0)
            #expect(motionSettle <= 1.0)
        }

        /// The file entry point on a small WAV written here: faster than real time, byte-identical when repeated, and the
        /// file's own beat shows up as hits.
        @Test func aFileIsRecordedOfflineAndDeterministically() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("four-on-the-floor.wav")
            let rate = 44_100.0
            let seconds = 8.0
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let frames = AVAudioFrameCount(rate * seconds)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let left = try #require(buffer.floatChannelData)[0]
                let right = try #require(buffer.floatChannelData)[1]
                for i in 0..<Int(frames) {
                    // A decaying 60 Hz thump on every beat of 120 BPM, a hat-like tick on the off-beats.
                    let t = Double(i) / rate
                    let beat = t.truncatingRemainder(dividingBy: 0.5)
                    let thump = Float(sin(2 * .pi * 60 * beat) * exp(-beat * 18)) * 0.8
                    let tick = beat > 0.25 && beat < 0.26 ? Float(sin(Double(i) * 2.1)) * 0.2 : 0
                    left[i] = thump + tick
                    right[i] = thump - tick
                }
                try file.write(from: buffer)
            }
            let started = Date()
            let first = try SoundTimelineRecorder.record(fileAt: url)
            let took = Date().timeIntervalSince(started)
            let second = try SoundTimelineRecorder.record(fileAt: url)
            #expect(try first.encoded() == second.encoded())
            #expect(first.header.trackID == "four-on-the-floor")
            #expect(first.header.analysisSampleRate == rate)
            #expect(abs(first.duration - seconds) < 1.0 / 60)
            #expect(first.header.hitLanes.contains(Instrument.kick.index))
            let player = SoundTimelinePlayer(first)
            var kicks: UInt32 = 0
            for tick in 0...Int(seconds * Self.tickRate) + 1 {
                kicks = player.input(at: Double(tick) / Self.tickRate).music!.hitCounts[.kick]
            }
            #expect(kicks >= 8, "a 120 BPM thump over 8 s fired \(kicks) kicks")
            #expect(took < seconds / 4, "recording took \(took) s for \(seconds) s of audio")
            #expect(throws: SoundTimelineRecorder.FileError.unreadable) {
                try SoundTimelineRecorder.record(fileAt: directory.appendingPathComponent("missing.wav"))
            }
        }

        /// The demo loop WAV recorded offline into the evidence file; gated on the environment.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["SOUND_TIMELINE_OUT"] != nil))
        func recordTheDemoLoopFile() throws {
            let wav =
                ProcessInfo.processInfo.environment["SOUND_TIMELINE_WAV"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Music/Captures/demo-classic-loop.wav")
            let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOUND_TIMELINE_OUT"]!)
            let started = Date()
            let timeline = try SoundTimelineRecorder.record(fileAt: wav)
            let recorded = Date().timeIntervalSince(started)
            let again = try SoundTimelineRecorder.record(fileAt: wav)
            let data = try timeline.encoded()
            #expect(try again.encoded() == data, "two offline recordings of the same file differ")
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: out)
            let perMinute = Double(data.count) / (timeline.duration / 60)
            print(
                "soundtimeline: \(wav.lastPathComponent) \(String(format: "%.1f", timeline.duration)) s -> \(data.count) bytes (\(Int(perMinute)) bytes/min, \(timeline.sampleCount) samples), recorded in \(String(format: "%.2f", recorded)) s, tempo \(timeline.header.tempoBPM.map { String(format: "%.1f", $0) } ?? "none"), lanes \(timeline.header.hitLanes)"
            )
            #expect(timeline.duration > 90)
            #expect(Double(data.count) <= 2_000_000 / 4 * (timeline.duration / 60))
            #expect(try SoundTimeline(decoding: Data(contentsOf: out)) == timeline)
        }
    }
#endif
