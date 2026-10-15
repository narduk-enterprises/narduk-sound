import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// Replays a `SoundTimeline` against the track's playback time: `input(at:)` returns the `SoundVisualInput` (frame and
/// `MusicContext`) that `SoundVisualState.update(_:now:)` consumes, the way a live `SoundFrameSource` and
/// `SoundMusicInference` would have produced it.
///
/// - The spectrum, chroma and levels are interpolated between the two samples around `time`; the waveform, section and
///   flags come from the nearest sample. Every new `time` is a new frame (`sequence` counts up from 1), asking again
///   for the same `time` returns the same input.
/// - The beat clock is the recorded position interpolated between samples, so `step` advances on the tempo between
///   samples and never passes the next sample's step.
/// - Hit counters are the player's own, and only ever go up. Hits that fall between two calls a short way apart (up to
///   `continuityWindow` seconds) are added to them; a seek in either direction, or a gap longer than the window, adds
///   none, so the state sees no burst of hits after a jump. A backward seek lowers `step`, which `SoundVisualState`
///   already treats as the engine's seek (`music.step < lastStep`).
/// - At or past the end it holds the last sample with `isRunning` false.
///
/// Not thread-safe: own one per drawing clock.
public final class SoundTimelinePlayer {
    /// Calls this far apart (seconds of track time) or closer count the hits between them.
    public static let continuityWindow = 0.5

    public let timeline: SoundTimeline

    private let lanes: [Int]
    /// Running hit totals per recorded lane, sample-major (`sample * lanes.count + lane`).
    private let cumulative: [UInt32]
    private var counters = HitCounters()
    private var lastSample: Int?
    private var lastTime = -Double.infinity
    private var sequence: UInt64 = 0
    private var cached: (time: Double, input: SoundVisualInput)?
    private var endHeld: SoundVisualInput?
    private var waveformSample = -1
    private var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)

    public init(_ timeline: SoundTimeline) {
        self.timeline = timeline
        let lanes = timeline.header.hitLanes
        self.lanes = lanes
        var running = [UInt32](repeating: 0, count: timeline.sampleCount * lanes.count)
        var totals = [UInt32](repeating: 0, count: lanes.count)
        for k in 0..<timeline.sampleCount {
            for l in 0..<lanes.count {
                totals[l] &+= UInt32(timeline.hits[k * lanes.count + l])
                running[k * lanes.count + l] = totals[l]
            }
        }
        cumulative = running
    }

    /// Forgets where the playback was (a new track, a new state): the next call adopts the counters without hits.
    public func reset() {
        counters = HitCounters()
        lastSample = nil
        lastTime = -.infinity
        sequence = 0
        cached = nil
        endHeld = nil
        waveformSample = -1
    }

    /// What the visualizers see `time` seconds into the track.
    public func input(at time: Double) -> SoundVisualInput {
        let n = timeline.sampleCount
        guard n > 0 else { return SoundVisualInput(frame: SoundFrame(), music: MusicContext()) }
        let time = time.isFinite ? max(time, 0) : 0
        if let cached, cached.time == time { return cached.input }
        let rate = timeline.gridRate
        let ended = time >= timeline.duration
        // Past the end the picture holds: the same input (and sequence) however long the caller keeps asking.
        if ended, let held = endHeld { return held }
        let position = ended ? Double(n - 1) : min(time * rate + 1e-9, Double(n - 1))
        let i = min(Int(position), n - 1)
        let j = min(i + 1, n - 1)
        let f = ended ? 0 : Float(position - Double(i))
        let near = f >= 0.5 ? j : i

        // Hit counters: add the hits passed on a continuous forward step; nothing on a seek.
        if let previous = lastSample, time >= lastTime, time - lastTime <= Self.continuityWindow {
            if near > previous { addHits(from: previous, to: near) }
        }
        lastSample = near
        lastTime = time

        let frame = makeFrame(time: time, i: i, j: j, f: f, near: near)
        let music = makeContext(i: i, j: j, f: ended ? 0 : Double(f), near: near, ended: ended)
        let input = SoundVisualInput(frame: frame, music: music)
        cached = (time, input)
        endHeld = ended ? input : nil
        return input
    }

    private func addHits(from: Int, to: Int) {
        for (l, lane) in lanes.enumerated() {
            counters.lanes[lane] &+= cumulative[to * lanes.count + l] &- cumulative[from * lanes.count + l]
        }
    }

    // MARK: Frame

    private func makeFrame(time: Double, i: Int, j: Int, f: Float, near: Int) -> SoundFrame {
        let bands = SoundTimeline.bandCount
        let pitches = SoundTimeline.chromaCount
        let inverse: Float = 1.0 / 255
        var spectrum = [Float](repeating: 0, count: bands)
        for b in 0..<bands {
            let a = Float(timeline.spectrum[i * bands + b])
            let c = Float(timeline.spectrum[j * bands + b])
            spectrum[b] = (a + (c - a) * f) * inverse
        }
        var chroma = [Float](repeating: 0, count: pitches)
        for p in 0..<pitches {
            let a = Float(timeline.chroma[i * pitches + p])
            let c = Float(timeline.chroma[j * pitches + p])
            chroma[p] = (a + (c - a) * f) * inverse
        }
        let rms = Float(timeline.rmsCentiDB[i]) + (Float(timeline.rmsCentiDB[j]) - Float(timeline.rmsCentiDB[i])) * f
        let peak =
            Float(timeline.peakCentiDB[i]) + (Float(timeline.peakCentiDB[j]) - Float(timeline.peakCentiDB[i])) * f
        let stored = near / timeline.header.waveformEvery
        if waveformSample != stored {
            restoreWaveform(stored)
            waveformSample = stored
        }
        sequence += 1
        return SoundFrame(
            sequence: sequence, time: time, spectrum: spectrum, waveform: waveform, peakDB: peak / 100,
            rmsDB: rms / 100,
            chroma: chroma)
    }

    /// The stored points are box means of 8 samples, centred at 3.5 + 8k; a Catmull-Rom curve through them gives the 512
    /// the shaders index (and the scope's trigger scans).
    private func restoreWaveform(_ sample: Int) {
        let points = timeline.header.waveformPoints
        let base = sample * points
        let count = SoundFrame.waveformCount
        let span = Float(count) / Float(points)
        func point(_ k: Int) -> Float { SoundTimeline.expand(timeline.waveform[base + min(max(k, 0), points - 1)]) }
        for x in 0..<count {
            let u = (Float(x) + 0.5) / span - 0.5
            let k = Int(u.rounded(.down))
            let t = u - Float(k)
            let p0 = point(k - 1)
            let p1 = point(k)
            let p2 = point(k + 1)
            let p3 = point(k + 2)
            let value =
                0.5
                * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (-p0 + 3 * p1 - 3 * p2 + p3) * t
                    * t * t)
            waveform[x] = min(max(value, -1), 1)
        }
    }

    // MARK: Context

    private func makeContext(i: Int, j: Int, f: Double, near: Int, ended: Bool) -> MusicContext {
        let header = timeline.header
        let first = Double(timeline.position[i])
        let second = Double(timeline.position[j])
        // Between two samples the clock runs from one position to the next; across a reset it holds.
        let clock: Double
        if j != i, second >= first, second - first <= 8 {
            clock = first + (second - first) * f
        } else {
            clock = first
        }
        let step = Int(clock.rounded(.down))
        let flags = timeline.flags[near]
        let sectionPhase = clock / 4 - (clock / 4).rounded(.down)
        let phrase = max(header.stepsPerPhrase, 1)
        return MusicContext(
            hitCounts: counters, step: step, section: SoundTimeline.section(code: flags),
            energy: Float(timeline.energy[near]) / 255,
            wobblePhase: Float((sectionPhase * 2).truncatingRemainder(dividingBy: 1)),
            wobbleCutoff: Float(timeline.cutoff[near]) / 255, isRunning: !ended && flags & 8 != 0,
            secondsPerStep: Double(timeline.stepDuration[near]) * SoundTimeline.stepUnit,
            stepsPerBar: header.stepsPerBar, stepsPerPhrase: header.stepsPerPhrase,
            phraseProgress: Float(((step % phrase) + phrase) % phrase) / Float(phrase),
            buildThreshold: header.buildThreshold, dropThreshold: header.dropThreshold, dropQueued: flags & 16 != 0)
    }
}
