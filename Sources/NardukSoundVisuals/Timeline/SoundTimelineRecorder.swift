import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// Records a `SoundTimeline` from a stream of `SoundFrame`s: each frame runs through a `SoundMusicInference` (at the
/// frame rate the inference expects, ~60 Hz) and the recorder keeps, at every grid time, the latest frame and context
/// at or before it. Feed it from any source (a live tap, an offline renderer, `record(fileAt:)`); frame times are
/// seconds into the track and must not go backwards.
///
/// Not thread-safe: own one per recording and call it from one thread.
public final class SoundTimelineRecorder {
    public let trackID: String
    public let gridRate: Double
    /// The inference every `record(_:)` frame runs through.
    public let inference: SoundMusicInference
    /// The sample rate of the audio the frames were analyzed from, and the frames' rate: stamped in the header.
    public let analysisSampleRate: Double
    public let analysisRate: Double
    /// Points of each stored waveform (a divisor of 512) and how often one is stored (every n-th sample).
    public let waveformPoints: Int
    public let waveformEvery: Int

    private struct Pending {
        var frame: SoundFrame
        var music: MusicContext
        /// The frame time at which `music.step` last changed, for the fraction through the step.
        var stepChanged: Double
    }

    private var pending: Pending?
    private var lastStep = Int.min
    private var lastStepChanged = 0.0
    private var lastFrameTime = -Double.infinity
    private var nextSample = 0
    private var recorded = HitCounters()
    private var usedInference = false
    private var firstContext: MusicContext?

    private var spectrum: [UInt8] = []
    private var chroma: [UInt8] = []
    private var rms: [Int16] = []
    private var peak: [Int16] = []
    private var flags: [UInt8] = []
    private var cutoff: [UInt8] = []
    private var energy: [UInt8] = []
    private var position: [Float] = []
    private var stepDuration: [UInt16] = []
    /// All 32 lanes while recording; `finish` keeps the lanes that fired.
    private var hits: [UInt8] = []
    private var waveform: [Int8] = []

    public init(
        trackID: String, gridRate: Double = SoundTimeline.defaultGridRate, analysisSampleRate: Double = 0,
        analysisRate: Double = 60, waveformPoints: Int = SoundTimeline.waveformPoints,
        waveformEvery: Int = SoundTimeline.defaultWaveformEvery, inference: SoundMusicInference = SoundMusicInference()
    ) {
        precondition(waveformPoints > 0 && SoundFrame.waveformCount % waveformPoints == 0 && waveformEvery > 0)
        self.waveformPoints = waveformPoints
        self.waveformEvery = waveformEvery
        self.analysisSampleRate = analysisSampleRate
        self.analysisRate = analysisRate
        self.trackID = trackID
        self.gridRate = gridRate
        self.inference = inference
    }

    /// The number of grid samples emitted so far.
    public var sampleCount: Int { nextSample }

    /// Hears `frame` and records the context the inference says about it.
    public func record(_ frame: SoundFrame) {
        usedInference = true
        record(frame, music: inference.update(frame))
    }

    /// Records `frame` with a context from elsewhere (the music engine, a conductor).
    public func record(_ frame: SoundFrame, music: MusicContext) {
        let time = frame.time
        guard time >= lastFrameTime else { return }
        lastFrameTime = time
        let first = pending == nil
        if let pending, !first {
            emit(through: time, using: pending)
        }
        if music.step != lastStep {
            lastStep = music.step
            lastStepChanged = time
        }
        pending = Pending(frame: frame, music: music, stepChanged: lastStepChanged)
        if first {
            recorded = music.hitCounts
            firstContext = music
            emit(through: time, using: pending!)
        }
    }

    /// The time of the next grid sample.
    private var nextTime: Double { Double(nextSample) / gridRate }

    /// Emits the samples strictly before `time` from `pending`.
    private func emit(through time: Double, using pending: Pending) {
        while nextTime < time - 1e-9 { emitSample(at: nextTime, from: pending) }
    }

    private func emitSample(at time: Double, from pending: Pending) {
        let frame = pending.frame
        let music = pending.music
        for band in 0..<SoundTimeline.bandCount {
            spectrum.append(SoundTimeline.unit(band < frame.spectrum.count ? frame.spectrum[band] : 0))
        }
        for pitch in 0..<SoundTimeline.chromaCount {
            chroma.append(SoundTimeline.unit(pitch < frame.chroma.count ? frame.chroma[pitch] : 0))
        }
        rms.append(SoundTimeline.centiDB(frame.rmsDB))
        peak.append(SoundTimeline.centiDB(frame.peakDB))
        var bits = SoundTimeline.sectionCode(music.section)
        if music.isRunning { bits |= 8 }
        if music.dropQueued { bits |= 16 }
        flags.append(bits)
        cutoff.append(SoundTimeline.unit(music.wobbleCutoff))
        energy.append(SoundTimeline.unit(music.energy))
        let fraction =
            music.isRunning ? min(max((time - pending.stepChanged) / max(music.secondsPerStep, 0.01), 0), 0.97) : 0
        position.append(Float(Double(music.step) + fraction))
        stepDuration.append(UInt16(min(max((music.secondsPerStep / SoundTimeline.stepUnit).rounded(), 1), 65_535)))
        // A hit lane that fired more than 255 times in one sample carries the rest into the next samples.
        for lane in 0..<HitCounters.laneCount {
            let owed = music.hitCounts.lanes[lane] &- recorded.lanes[lane]
            let paid = UInt8(min(owed, 255))
            recorded.lanes[lane] &+= UInt32(paid)
            hits.append(paid)
        }
        if nextSample % waveformEvery == 0 {
            let points = waveformPoints
            let stride = SoundFrame.waveformCount / points
            for point in 0..<points {
                var sum: Float = 0
                for k in 0..<stride {
                    let index = point * stride + k
                    sum += index < frame.waveform.count ? frame.waveform[index] : 0
                }
                waveform.append(SoundTimeline.compand(sum / Float(stride)))
            }
        }
        nextSample += 1
    }

    /// Ends the recording and returns the timeline. `duration` is the audio's length in seconds; by default the time of
    /// the last frame. The last sample is the first grid time at or after it, so the final frame is always captured.
    public func finish(duration: Double? = nil) -> SoundTimeline {
        if let pending {
            let end = max(duration ?? lastFrameTime, lastFrameTime)
            while nextSample == 0 || nextTime - 1.0 / gridRate < end - 1e-9 { emitSample(at: nextTime, from: pending) }
        }
        let n = nextSample
        var lanes: [Int] = []
        for lane in 0..<HitCounters.laneCount {
            var total = 0
            for k in 0..<n { total += Int(hits[k * HitCounters.laneCount + lane]) }
            if total > 0 { lanes.append(lane) }
        }
        var kept: [UInt8] = []
        kept.reserveCapacity(n * lanes.count)
        for k in 0..<n { for lane in lanes { kept.append(hits[k * HitCounters.laneCount + lane]) } }
        let context = firstContext ?? MusicContext()
        let header = SoundTimeline.Header(
            formatVersion: SoundTimeline.formatVersion, trackID: trackID,
            duration: max(duration ?? lastFrameTime, lastFrameTime, 0), gridRate: gridRate, sampleCount: n,
            tempoBPM: usedInference ? inference.tempoBPM : nil, hitLanes: lanes,
            waveformPoints: waveformPoints, waveformEvery: waveformEvery,
            stepsPerBar: context.stepsPerBar,
            stepsPerPhrase: context.stepsPerPhrase, buildThreshold: context.buildThreshold,
            dropThreshold: context.dropThreshold, analysisSampleRate: analysisSampleRate,
            analysisRate: analysisRate, inference: usedInference ? .current : nil)
        return SoundTimeline(
            header: header, spectrum: spectrum, chroma: chroma, rmsCentiDB: rms, peakCentiDB: peak, flags: flags,
            cutoff: cutoff, energy: energy, position: position, stepDuration: stepDuration, hits: kept,
            waveform: waveform)
    }

}
