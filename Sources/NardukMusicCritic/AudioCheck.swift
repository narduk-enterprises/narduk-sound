import Foundation
import NardukMusicCore
import NardukMusicRender
import NardukSoundAnalysis

/// What a render of a song sounds like to a meter: clipping, clicks, silence, loudness, and (for a render the critic
/// made itself) drum timing and render cost. See `AudioCheck` and `docs/song-critic.md`.
public struct AudioReport: Sendable, Hashable, Codable {
    public var seconds: Double
    /// Samples (either channel) at or above `AudioCheck.clipLevel` full scale.
    public var clippedSamples: Int
    /// Isolated sample-to-sample discontinuities (see `AudioCheck.clicks`).
    public var clicks: Int
    /// When the first few clicks happen, in seconds.
    public var clickTimes: [Double]
    /// Stretches quieter than `AudioCheck.silenceLevel` that last longer than one bar.
    public var silenceGaps: Int
    /// The longest such stretch, in seconds (0 when there is none).
    public var longestSilence: Double
    /// RMS over the whole song, both channels, in dBFS.
    public var rmsDB: Double
    /// RMS of the loudest one-second window, in dBFS.
    public var loudestSecondDB: Double
    /// The largest sample, in dBFS.
    public var peakDB: Double
    /// Kick and snare onsets against the grid; nil for a render the critic did not make.
    public var drums: DrumTiming?
    /// How long the synth took per block; nil for a render the critic did not make.
    public var cost: RenderCost?

    /// Kick and snare onsets measured in a drums-only render of the same song.
    public struct DrumTiming: Sendable, Hashable, Codable {
        /// Kicks and snares whose onset was found.
        public var measured: Int
        /// Hits whose onset could not be told from the tail of the one before (a ghost note after a loud hit).
        public var unmeasured: Int
        /// The largest |onset - due|, in ms, where due is the hit's grid step plus its swing plus the limiter delay.
        public var worstOffsetMs: Double
        /// The mean |onset - due|, in ms.
        public var meanOffsetMs: Double
        /// When the worst hit lands, in seconds.
        public var worstAt: Double
        /// The largest swing the conductor asked for (how late of the straight grid a hit is meant to be), in ms.
        public var maxSwingMs: Double
    }

    /// The wall time of each `DropSynthCore.render` call against the block's real-time budget.
    public struct RenderCost: Sendable, Hashable, Codable {
        public var blocks: Int
        /// The real-time length of one block, in ms (16.7 ms at 60 ticks a second).
        public var budgetMs: Double
        public var worstMs: Double
        public var meanMs: Double
        /// Blocks that took longer than `budgetMs`.
        public var overBudget: Int
        /// When the slowest block plays, in seconds.
        public var worstAt: Double
        /// The slowest tick's conductor work (signals and note writing), in ms; on the live engine this runs on the
        /// note pump, not the audio thread.
        public var worstPumpMs: Double
    }
}

/// Meters a rendered song (see `AudioReport`).
public enum AudioCheck {
    /// A sample at or above this (full scale 1) is clipped.
    public static let clipLevel: Float = 0.999
    /// A 10 ms window whose peak is below this (-60 dBFS) is silent.
    public static let silenceLevel: Float = 0.001
    /// A click's jump in the second difference must be this many times the largest one around it...
    public static let clickRatio = 4.0
    /// ...within this many seconds on either side (longer than the period of a 40 Hz saw, so its resets are "around")...
    public static let clickSideSeconds = 0.03
    /// ...and at least this big (about -34 dBFS), so the dither of a near-silent tail never counts.
    public static let clickFloor: Float = 0.02

    /// The result of `render(settings:seconds:signals:)`: the song, the conductor's notes, and its section and
    /// energy at every bar line.
    public struct Run: Sendable {
        public var audio: RenderedAudio
        public var report: AudioReport
        public var notes: [ScheduledNote]
        public var sections: [SongSection]
        public var energy: [Double]
        /// Whole bars rendered, and the mean length of a step over them (tracks may change the tempo).
        public var bars: Int
        public var secondsPerStep: Double
    }

    /// Renders `seconds` of a song through the offline tick loop (`OfflineRenderer`'s, timed), meters it, and renders
    /// it again with only its kicks and snares to time them. `signals` are delivered in the tick their time falls in;
    /// nil plays `SongCritic.energyWave`.
    public static func render(
        settings: SongSettings, seconds: Double, signals: [MusicSignal]? = nil, sampleRate: Double = 48_000
    ) -> Run {
        let waveBars = Int((seconds / (settings.secondsPerStep * Double(settings.stepsPerBar))).rounded(.up)) + 1
        let signals = signals ?? SongCritic.energyWave(bars: waveBars, settings: settings)
        let ticks = Int((seconds * OfflineRenderer.tickRate).rounded())
        let song = CriticRender(settings: settings, sampleRate: sampleRate)
        let audio = song.render(ticks: ticks, signals: signals)
        let steps = max(1, song.renderedStepPosition)
        let secondsPerStep = audio.seconds / steps
        var report = analyze(audio, barSeconds: secondsPerStep * Double(settings.stepsPerBar))
        report.cost = cost(song)
        let drums: Set<Instrument> = [.kick, .snare]
        let drumPass = CriticRender(
            settings: settings, sampleRate: sampleRate, filter: { drums.contains($0.instrument) }, tracked: drums)
        let drumAudio = drumPass.render(ticks: ticks, signals: signals)
        report.drums = drumTiming(drumAudio, due: drumPass.due, latency: drumPass.limiterLatency)
        let bars = min(song.sections.count, Int(steps) / settings.stepsPerBar)
        return Run(
            audio: audio, report: report, notes: song.notes, sections: Array(song.sections.prefix(bars)),
            energy: Array(song.energy.prefix(bars)), bars: bars, secondsPerStep: secondsPerStep)
    }

    /// Meters a render: clipping, clicks, silence gaps longer than `barSeconds`, and loudness.
    public static func analyze(_ audio: RenderedAudio, barSeconds: Double) -> AudioReport {
        var clipped = 0
        for channel in [audio.left, audio.right] {
            for sample in channel where abs(sample) >= clipLevel { clipped += 1 }
        }
        let clickTimes = clicks(audio)
        let silence = silenceGaps(audio, longerThan: barSeconds)
        let loudness = loudness(audio)
        return AudioReport(
            seconds: audio.seconds, clippedSamples: clipped, clicks: clickTimes.count,
            clickTimes: Array(clickTimes.prefix(16)), silenceGaps: silence.count, longestSilence: silence.longest,
            rmsDB: loudness.rms, loudestSecondDB: loudness.loudestSecond, peakDB: Double(Loudness.decibels(audio.peak)),
            drums: nil, cost: nil)
    }

    // MARK: Clicks

    /// Times (seconds) of isolated discontinuities on either channel, merged within 1 ms.
    ///
    /// A click is a jump nothing around it explains: the second difference |x[n] - 2x[n-1] + x[n-2]| (near zero on a
    /// smooth wave, large at a step) at least `clickFloor` and more than `clickRatio` times the largest second
    /// difference anywhere else within `clickSideSeconds` on either side. A snare's noise, a drum's attack and a saw
    /// or square wave's period resets all bring jumps of their own size with them, so they do not count; one step in
    /// otherwise smooth audio does.
    public static func clicks(_ audio: RenderedAudio) -> [Double] {
        let side = max(8, Int(audio.sampleRate * clickSideSeconds))
        var found: [Int] = []
        for channel in [audio.left, audio.right] {
            found += clicks(in: channel, side: side)
        }
        found.sort()
        var merged: [Int] = []
        let gap = Int(audio.sampleRate * 0.001)
        for index in found where merged.last.map({ index - $0 > gap }) ?? true { merged.append(index) }
        return merged.map { Double($0) / audio.sampleRate }
    }

    /// Indices of clicks in one channel, in one pass with O(`side`) memory: a running maximum of |d2| over the
    /// `side - guardBand` samples before each index, read `side` samples late so both neighbourhoods are known.
    static func clicks(in x: [Float], side: Int) -> [Int] {
        let guardBand = 3  // a step makes two adjacent spikes; skip the jump's own neighbours
        let length = side - guardBand
        guard x.count > 2 * side + 4, length > 0 else { return [] }
        let ring = side + guardBand + 2
        var jumps = [Float](repeating: 0, count: ring)
        var maxima = [Float](repeating: 0, count: ring)
        // Monotonic deque of (index, value), values decreasing from the front.
        var dequeIndex = [Int](repeating: 0, count: length + 1)
        var dequeValue = [Float](repeating: 0, count: length + 1)
        var head = 0
        var size = 0
        var out: [Int] = []
        var last = Int.min / 2
        for t in 0..<x.count {
            let jump = t < 2 ? 0 : abs(x[t] - 2 * x[t - 1] + x[t - 2])
            jumps[t % ring] = jump
            while size > 0, dequeValue[(head + size - 1) % (length + 1)] <= jump { size -= 1 }
            dequeIndex[(head + size) % (length + 1)] = t
            dequeValue[(head + size) % (length + 1)] = jump
            size += 1
            while dequeIndex[head] <= t - length {
                head = (head + 1) % (length + 1)
                size -= 1
            }
            maxima[t % ring] = dequeValue[head]
            // The candidate `side` samples back: its right neighbourhood ends now, its left one ended guardBand + 1
            // samples before it.
            let n = t - side
            guard n - guardBand - 1 >= length else { continue }
            let value = jumps[n % ring]
            guard value >= clickFloor, n - last > guardBand else { continue }
            let around = max(maxima[t % ring], maxima[(n - guardBand - 1) % ring])
            if value > Float(clickRatio) * around {
                out.append(n)
                last = n
            }
        }
        return out
    }

    // MARK: Silence and loudness

    /// Stretches of 10 ms windows whose peak is under `silenceLevel` on both channels, lasting over `seconds`.
    static func silenceGaps(_ audio: RenderedAudio, longerThan seconds: Double) -> (count: Int, longest: Double) {
        let window = max(1, Int(audio.sampleRate * 0.01))
        var run = 0
        var count = 0
        var longest = 0
        func close() {
            let length = run * window
            if Double(length) / audio.sampleRate > seconds {
                count += 1
                longest = max(longest, length)
            }
            run = 0
        }
        for start in Swift.stride(from: 0, to: audio.frameCount, by: window) {
            var peak: Float = 0
            for i in start..<min(audio.frameCount, start + window) {
                peak = max(peak, abs(audio.left[i]), abs(audio.right[i]))
            }
            if peak < silenceLevel { run += 1 } else { close() }
        }
        close()
        return (count, Double(longest) / audio.sampleRate)
    }

    /// RMS of the whole song and of its loudest one-second window, in dBFS, both channels, from
    /// `NardukSoundAnalysis.Loudness` per window (summed in Double so a long song keeps its precision).
    static func loudness(_ audio: RenderedAudio) -> (rms: Double, loudestSecond: Double) {
        let window = max(1, Int(audio.sampleRate))
        var power = 0.0
        var frames = 0
        var loudest = Double(Loudness.silenceDB)
        for start in Swift.stride(from: 0, to: audio.frameCount, by: window) {
            let count = min(window, audio.frameCount - start)
            var windowPower = 0.0
            for channel in [audio.left, audio.right] {
                let rms = channel.withUnsafeBufferPointer { buffer in
                    Loudness.measure(UnsafeBufferPointer(rebasing: buffer[start..<(start + count)])).rmsDB
                }
                windowPower += rms <= Loudness.silenceDB ? 0 : pow(10, Double(rms) / 10)
            }
            power += windowPower / 2 * Double(count)
            frames += count
            if count == window { loudest = max(loudest, decibels(power: windowPower / 2)) }
        }
        return (frames > 0 ? decibels(power: power / Double(frames)) : Double(Loudness.silenceDB), loudest)
    }

    static func decibels(power: Double) -> Double {
        power > 1e-12 ? 10 * log10(power) : Double(Loudness.silenceDB)
    }

    // MARK: Drums and cost

    /// Finds each due kick and snare's onset in a drums-only render.
    ///
    /// The onset is where the first difference |x[n] - x[n-1]| (the attack's edge, small on a decaying low tail) first
    /// reaches 10% of its maximum (or 1.5 times the largest edge in the 10 ms before, if that is higher) in a window
    /// 5 ms before to 40 ms after the due sample. A hit is unmeasured when that maximum is under three times the level
    /// in the 10 ms before the window, that is under the previous hit's tail.
    static func drumTiming(_ audio: RenderedAudio, due: [CriticRender.DueHit], latency: Int) -> AudioReport.DrumTiming {
        let rate = audio.sampleRate
        let mono = zip(audio.left, audio.right).map { ($0 + $1) * 0.5 }
        @inline(__always) func edge(_ n: Int) -> Float { n < 1 || n >= mono.count ? 0 : abs(mono[n] - mono[n - 1]) }
        let before = Int(rate * 0.005)
        let after = Int(rate * 0.04)
        let quiet = Int(rate * 0.01)
        var offsets: [(offset: Int, at: Int)] = []
        var unmeasured = 0
        var maxSwing = 0
        var seen = Set<Int>()
        for hit in due.sorted(by: { $0.sample < $1.sample }) {
            maxSwing = max(maxSwing, hit.swing)
            let expected = hit.sample + latency
            // A kick and a snare on one step share one onset.
            guard seen.insert(expected).inserted else { continue }
            let lo = expected - before
            let hi = expected + after
            guard lo - quiet >= 1, hi < mono.count else { continue }
            var floor: Float = 0
            for n in (lo - quiet)..<lo { floor = max(floor, edge(n)) }
            var peak: Float = 0
            for n in lo..<hi { peak = max(peak, edge(n)) }
            guard peak > 1e-4, peak >= 3 * floor else {
                unmeasured += 1
                continue
            }
            let threshold = max(0.1 * peak, 1.5 * floor)
            var onset = lo
            while onset < hi, edge(onset) < threshold { onset += 1 }
            offsets.append((onset - expected, expected))
        }
        let ms = 1000 / rate
        let worst = offsets.max { abs($0.offset) < abs($1.offset) }
        let mean = offsets.isEmpty ? 0 : offsets.reduce(0.0) { $0 + Double(abs($1.offset)) } / Double(offsets.count)
        return AudioReport.DrumTiming(
            measured: offsets.count, unmeasured: unmeasured, worstOffsetMs: Double(abs(worst?.offset ?? 0)) * ms,
            meanOffsetMs: mean * ms, worstAt: Double(worst?.at ?? 0) / rate, maxSwingMs: Double(maxSwing) * ms)
    }

    static func cost(_ render: CriticRender) -> AudioReport.RenderCost {
        let budget = Double(render.framesPerTick) / render.sampleRate * 1000
        let ms = render.renderNanos.map { Double($0) / 1e6 }
        let worst = ms.indices.max { ms[$0] < ms[$1] } ?? 0
        return AudioReport.RenderCost(
            blocks: ms.count, budgetMs: budget, worstMs: ms.isEmpty ? 0 : ms[worst],
            meanMs: ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count), overBudget: ms.filter { $0 > budget }.count,
            worstAt: Double(worst) / OfflineRenderer.tickRate,
            worstPumpMs: (render.pumpNanos.max().map { Double($0) / 1e6 }) ?? 0)
    }
}
