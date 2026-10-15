import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// Hears the music in a `SoundFrame` stream that has no conductor (a microphone, a file, a loopback device such as
/// BlackHole) and says what it hears as a `MusicContext`, so the visualizers that react to hits, a beat clock, energy
/// and sections (docs/sound-contract.md section 2) move for recorded music the way they move for the engine's song.
///
/// What it infers, and from what:
/// - **Hits.** Spectral flux (the half-wave rectified rise of the bands since the last frame) in three ranges, about
///   30 ... 200 Hz, 200 Hz ... 2 kHz and 2.4 ... 16 kHz, against an adaptive threshold (a running mean plus a multiple
///   of the running deviation) with a refractory time per lane, counted on the `kick`, `snare` and `hat` lanes.
/// - **Tempo and beat.** The onset strength is resampled onto a 50 Hz grid; every half second its autocorrelation over
///   60 ... 200 BPM picks a period, scored with its double- and quadruple-time subdivisions (a real beat has them, the
///   dotted-note alias a breakbeat throws up does not), averaged over the last several estimates and weighted gently
///   toward 120 BPM. The clock locks when four estimates in a row agree and leaves a locked tempo only for one that
///   scores clearly higher. Kick onsets pull the
///   beat phase, so `step` lands on the drums.
/// - **Energy and section.** A fast loudness against a slow ceiling and floor, plus onset density, gives `energy`;
///   energy held near the loudest the song has reached is a drop (`drop` and `drop2` alternate, with an `impact` hit on
///   entry), a fall well below it is a breakdown and rising energy is a build.
///
/// Nothing here is a bar line: `step` counts 16ths from the first locked beat, so bars and phrases are a convention,
/// not the song's. Notes stay empty (the visualizers read the analysis chroma). Every buffer is allocated in `init`;
/// `update` never allocates. Not thread-safe: own one per source and call it from one thread.
public final class SoundMusicInference {
    /// The onset-strength grid the tempo is measured on, and how much of it (8 s).
    public static let gridRate = 50.0
    public static let gridCount = 400
    public static let minBPM = 60.0
    public static let maxBPM = 200.0
    /// The tempo the clock runs at before a lock (the engine's default).
    public static let defaultBPM = 140.0
    /// How often the tempo is re-estimated.
    static let tempoInterval = 0.5
    /// The share of the heard `loudness` published as the context's `energy` (see `update`).
    public static let contextEnergyScale: Float = 0.45
    static let minLag = Int(gridRate * 60 / maxBPM)  // 15
    static let maxLag = Int(gridRate * 60 / minBPM)  // 50
    /// The shortest lag correlated: a quadruple-time subdivision of the fastest tempo.
    static let subdivisionLag = minLag / 4
    /// Estimates in a row that must agree before the clock locks or switches.
    static let agreementsToLock = 4
    /// Estimates in a row that must agree on another tempo before a locked one is left: a two-bar build of snare rolls
    /// (3.4 s at 140 BPM) must not pull the clock to an alias.
    static let agreementsToSwitch = 8
    /// Below this RMS the source is silent: the clock stops and the section rests.
    public static let silenceDB: Float = -65
    /// A gap this long between frames (the view was hidden) resets the flux baseline instead of hearing one huge onset.
    static let staleGap = 0.5

    /// An onset detector over one range of bands, counted on one instrument lane.
    struct Lane {
        let instrument: Instrument
        let bands: Range<Int>
        /// The least flux that can be an onset, in band units (0 ... 1 per band).
        let floor: Float
        /// How many running deviations above the running mean an onset must rise.
        let sigma: Float
        /// Two onsets closer than this are one.
        let refractory: Double
        /// Its weight in the onset strength the tempo is measured on.
        let weight: Float

        var mean: Float = 0
        var deviation: Float = 0
        var lastFlux: Float = 0
        var lastOnset = -Double.infinity
        /// The flux above the running mean this frame, 0 when below it.
        var strength: Float = 0
    }

    static let kickLane = Lane(instrument: .kick, bands: 4..<22, floor: 0.012, sigma: 1.8, refractory: 0.11, weight: 1)
    static let snareLane = Lane(
        instrument: .snare, bands: 22..<44, floor: 0.01, sigma: 2.0, refractory: 0.11, weight: 0.7)
    static let hatLane = Lane(
        instrument: .hat, bands: 46..<64, floor: 0.008, sigma: 1.3, refractory: 0.05, weight: 0.3)

    private var kick = SoundMusicInference.kickLane
    private var snare = SoundMusicInference.snareLane
    private var hat = SoundMusicInference.hatLane

    private let previousBands = FixedBuffer<Float>(count: SoundFrame.spectrumCount, repeating: 0)
    private let grid = FixedBuffer<Float>(count: gridCount, repeating: 0)
    private let window = FixedBuffer<Float>(count: gridCount, repeating: 0)
    private let correlation = FixedBuffer<Float>(count: maxLag + 1, repeating: 0)
    /// The correlation averaged over the last several estimates (~10 s): the beat is steadier than any one window.
    private let averaged = FixedBuffer<Float>(count: maxLag + 1, repeating: 0)
    private var estimates = 0
    private var gridHead = 0
    private var gridTime = -Double.infinity
    private var gridFilled = 0
    private var strength: Float = 0
    private var lastTempoTime = -Double.infinity

    private var lastSequence: UInt64 = 0
    private var lastTime = 0.0
    private var counts = HitCounters()

    // Tempo and clock.
    private var bpm = SoundMusicInference.defaultBPM
    private var candidateBPM = 0.0
    private var agreements = 0
    private var locked = false
    private var stepPosition = 0.0
    private var lastStep = 0
    private var lockTime = -Double.infinity

    // Energy and section.
    private var heard = false
    private var loud: Float = SoundFrame.silenceDB
    private var ceiling: Float = SoundFrame.silenceDB
    private var floorDB: Float = SoundFrame.silenceDB
    private var density: Float = 0
    private var energySlow: Float = 0
    /// The most energy the song has reached, falling slowly: what a drop is measured against.
    private var energyPeak: Float = 0
    /// Loudness alone, smoothed like `energy`: sections follow it, since a snare roll makes a build as busy as a drop.
    private(set) var level: Float = 0
    /// The loudness and onset density heard, 0 ... 1: what drives the sections. Not the context's `energy` (see `update`).
    public var loudness: Float { energy }
    private(set) var levelPeak: Float = 0
    /// `level` smoothed over ~2 s: what a drop has to rise above.
    private(set) var levelSlow: Float = 0
    private var heardSince = -Double.infinity
    private var midLevel: Float = 0
    private var silentSince = -Double.infinity
    private var highSince = -Double.infinity
    private var midSince = -Double.infinity
    private var lowSince = -Double.infinity
    private var sectionSince = -Double.infinity
    private var dropsEntered = 0
    /// The loudness peak when the current drop began: a drop much louder than it is a new drop.
    private var dropEntryPeak: Float = 0
    private var energy: Float = 0
    private var section = SongSection.intro

    /// The last context `update` produced.
    public private(set) var latest = MusicContext()
    /// The tempo the clock runs at, in BPM; nil until a tempo is locked.
    public var tempoBPM: Double? { locked ? bpm : nil }
    /// True while the beat clock follows a measured tempo.
    public var isLocked: Bool { locked }

    public init() {}

    /// Forgets everything heard, as if newly created.
    public func reset() {
        kick = Self.kickLane
        snare = Self.snareLane
        hat = Self.hatLane
        let bands = previousBands.mutable
        for i in 0..<previousBands.count { bands[i] = 0 }
        let cells = grid.mutable
        for i in 0..<grid.count { cells[i] = 0 }
        gridHead = 0
        gridTime = -.infinity
        gridFilled = 0
        let lags = averaged.mutable
        for i in 0..<averaged.count { lags[i] = 0 }
        estimates = 0
        strength = 0
        lastTempoTime = -.infinity
        lastSequence = 0
        lastTime = 0
        counts = HitCounters()
        bpm = Self.defaultBPM
        candidateBPM = 0
        agreements = 0
        locked = false
        stepPosition = 0
        lastStep = 0
        lockTime = -.infinity
        heard = false
        loud = SoundFrame.silenceDB
        ceiling = SoundFrame.silenceDB
        floorDB = SoundFrame.silenceDB
        density = 0
        energySlow = 0
        energyPeak = 0
        level = 0
        levelPeak = 0
        levelSlow = 0
        heardSince = -.infinity
        midLevel = 0
        silentSince = -.infinity
        highSince = -.infinity
        midSince = -.infinity
        lowSince = -.infinity
        sectionSince = -.infinity
        dropsEntered = 0
        dropEntryPeak = 0
        energy = 0
        section = .intro
        latest = MusicContext()
    }

    /// Hears `frame` and returns the context so far. A frame already heard (same `sequence`) returns `latest` unchanged.
    @discardableResult
    public func update(_ frame: SoundFrame) -> MusicContext {
        guard frame.sequence != lastSequence else { return latest }
        let now = frame.time
        let first = lastSequence == 0
        let stale = first || now - lastTime > Self.staleGap || now < lastTime
        let dt = stale ? 1.0 / 60 : min(max(now - lastTime, 0.001), 0.1)
        lastSequence = frame.sequence
        lastTime = now
        if first {
            sectionSince = now
            gridTime = now
        }

        let silent = frame.rmsDB < Self.silenceDB
        if silent {
            if silentSince == -.infinity { silentSince = now }
        } else {
            silentSince = -.infinity
        }
        let resting = silent && now - silentSince > 1.0

        hear(frame, now: now, dt: dt, stale: stale, silent: silent)
        feedGrid(now)
        if now - lastTempoTime >= Self.tempoInterval, gridFilled >= Self.gridCount * 3 / 8 {
            lastTempoTime = now
            estimateTempo()
        }
        advanceClock(dt: dt, resting: resting)
        updateEnergy(frame, dt: Float(dt), silent: silent, resting: resting)
        updateSection(now: now, resting: resting)

        let running = heard && !resting
        let secondsPerStep = 60 / bpm / 4
        let phase = Float(stepPosition / 4 - (stepPosition / 4).rounded(.down))
        // `energy` is the conductor's slot in the context. Published as 0 it left every visualizer that reads it dark
        // or still on a real song (Fireworks gates its whole show on it); published as the full `loudness` it makes
        // the shaders that light by it (the plasma, the warp grid) about twice as busy as the tuning for the
        // engine's songs. `contextEnergyScale` is the share of the heard loudness that goes in: the largest one
        // that keeps the plasma off the strobe limit, which is also enough to light the Fireworks (see
        // docs/visual-scorecard.md). The loudness itself stays public as `loudness` and drives the sections.
        latest = MusicContext(
            hitCounts: counts, step: lastStep, section: section, energy: energy * Self.contextEnergyScale,
            wobblePhase: (phase * 2).truncatingRemainder(dividingBy: 1), wobbleCutoff: midLevel, isRunning: running,
            secondsPerStep: secondsPerStep, stepsPerBar: 16, stepsPerPhrase: 128,
            phraseProgress: Float(lastStep % 128) / 128, buildThreshold: 0.55, dropThreshold: 0.4,
            dropQueued: section == .build && energy > 0.55)
        return latest
    }

    // MARK: Onsets

    private func hear(_ frame: SoundFrame, now: Double, dt: Double, stale: Bool, silent: Bool) {
        let previous = previousBands.mutable
        let count = min(frame.spectrum.count, previousBands.count)
        var kickFlux: Float = 0
        var snareFlux: Float = 0
        var hatFlux: Float = 0
        var mid: Float = 0
        frame.spectrum.withUnsafeBufferPointer { bands in
            if stale {
                for i in 0..<count { previous[i] = bands[i] }
            }
            kickFlux = Self.flux(bands, previous, kick.bands, count)
            snareFlux = Self.flux(bands, previous, snare.bands, count)
            hatFlux = Self.flux(bands, previous, hat.bands, count)
            for i in 0..<count { previous[i] = bands[i] }
            var sum: Float = 0
            for i in 16..<min(40, count) { sum += bands[i] }
            mid = sum / 24
        }
        midLevel += (mid - midLevel) * Float(min(1, dt * 8))

        var fired: Float = 0
        if Self.detect(&kick, flux: kickFlux, now: now, dt: dt, silent: silent) {
            counts.record(.kick)
            fired += 1
            pullBeat()
        }
        if Self.detect(&snare, flux: snareFlux, now: now, dt: dt, silent: silent) {
            counts.record(.snare)
            fired += 1
        }
        if Self.detect(&hat, flux: hatFlux, now: now, dt: dt, silent: silent) {
            counts.record(.hat)
            fired += 0.5
        }
        strength = kick.strength * kick.weight + snare.strength * snare.weight + hat.strength * hat.weight
        // Onsets per second, smoothed over ~2 s.
        density += (fired / Float(dt) - density) * Float(min(1, dt / 2))
    }

    /// Mean half-wave rectified rise over `range` of `bands` since `previous`.
    private static func flux(
        _ bands: UnsafeBufferPointer<Float>, _ previous: UnsafeMutablePointer<Float>, _ range: Range<Int>, _ count: Int
    ) -> Float {
        var sum: Float = 0
        let upper = min(range.upperBound, count)
        guard range.lowerBound < upper else { return 0 }
        for i in range.lowerBound..<upper { sum += max(0, bands[i] - previous[i]) }
        return sum / Float(upper - range.lowerBound)
    }

    /// Updates the lane's running statistics with `flux` and returns whether it is an onset.
    private static func detect(_ lane: inout Lane, flux: Float, now: Double, dt: Double, silent: Bool) -> Bool {
        let threshold = lane.floor + lane.mean + lane.sigma * lane.deviation
        let rising = flux > lane.lastFlux
        let fires = !silent && flux > threshold && rising && now - lane.lastOnset >= lane.refractory
        lane.strength = max(0, flux - lane.mean)
        // The baseline follows the signal over ~1.5 s, but an onset itself only nudges it: a steady beat must not
        // raise the bar it has to clear.
        let alpha = Float(min(1, dt / 1.5)) * (flux > threshold ? 0.25 : 1)
        lane.mean += (flux - lane.mean) * alpha
        lane.deviation += (abs(flux - lane.mean) - lane.deviation) * alpha
        lane.lastFlux = flux
        if fires { lane.lastOnset = now }
        return fires
    }

    // MARK: Tempo

    /// Holds the current onset strength on the grid up to `now`.
    private func feedGrid(_ now: Double) {
        let cells = grid.mutable
        let period = 1 / Self.gridRate
        var steps = 0
        while gridTime + period <= now, steps < Self.gridCount {
            gridTime += period
            gridHead = (gridHead + 1) % Self.gridCount
            cells[gridHead] = strength
            gridFilled = min(gridFilled + 1, Self.gridCount)
            steps += 1
        }
        if steps == Self.gridCount { gridTime = now }
    }

    private func estimateTempo() {
        let cells = grid.view
        let linear = window.mutable
        let n = Self.gridCount
        var mean: Float = 0
        for j in 0..<n {
            let value = cells[(gridHead + 1 + j) % n]
            linear[j] = value
            mean += value
        }
        mean /= Float(n)
        var r0: Float = 0
        for j in 0..<n {
            linear[j] -= mean
            r0 += linear[j] * linear[j]
        }
        guard r0 > 1e-6 else { return }
        let fresh = correlation.mutable
        let r = averaged.mutable
        estimates += 1
        let blend = max(1 / Float(estimates), 0.2)
        for lag in Self.subdivisionLag...Self.maxLag {
            var sum: Float = 0
            for j in lag..<n { sum += linear[j] * linear[j - lag] }
            fresh[lag] = sum / r0
            r[lag] += (fresh[lag] - r[lag]) * blend
        }
        var bestLag = 0
        var bestScore: Float = -.infinity
        for lag in Self.minLag...Self.maxLag {
            let score = score(lag, r)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0, r[bestLag] > 0.08 else { return }
        // Parabolic interpolation around the peak for a sub-cell period.
        var lag = Double(bestLag)
        if bestLag > Self.minLag, bestLag < Self.maxLag {
            let left = r[bestLag - 1]
            let right = r[bestLag + 1]
            let denominator = left - 2 * r[bestLag] + right
            if abs(denominator) > 1e-6 { lag += Double(0.5 * (left - right) / denominator) }
        }
        let measured = Self.gridRate * 60 / lag
        if locked, abs(measured - bpm) / bpm < 0.04 {
            bpm += (measured - bpm) * 0.3
            agreements = 0
            return
        }
        if candidateBPM > 0, abs(measured - candidateBPM) / candidateBPM < 0.04 {
            agreements += 1
            candidateBPM = (candidateBPM + measured) / 2
        } else {
            candidateBPM = measured
            agreements = 1
        }
        guard agreements >= (locked ? Self.agreementsToSwitch : Self.agreementsToLock) else { return }
        if locked {
            // Leave a locked tempo only for one that clearly outscores it.
            let currentLag = min(max(Int((Self.gridRate * 60 / bpm).rounded()), Self.minLag), Self.maxLag)
            guard bestScore > score(currentLag, r) * 1.4 else { return }
        }
        bpm = candidateBPM
        candidateBPM = 0
        agreements = 0
        if !locked {
            // The clock ran at the default tempo until now: keep its count (a tile's beat clock stays continuous)
            // and snap the phase to the nearest beat, which the kicks then pull into place.
            locked = true
            lockTime = lastTime
            stepPosition = (stepPosition / 4).rounded() * 4
            lastStep = Int(stepPosition)
        }
    }

    /// How much `lag` looks like the beat: its correlation plus its double- and quadruple-time subdivisions, under a
    /// gentle prior around 120 BPM.
    private func score(_ lag: Int, _ r: UnsafeMutablePointer<Float>) -> Float {
        let lagBPM = Self.gridRate * 60 / Double(lag)
        let octaves = log2(lagBPM / 130)
        let prior = Float(exp(-0.5 * (octaves / 0.75) * (octaves / 0.75)))
        let half = lag / 2 >= Self.subdivisionLag ? max(0, r[lag / 2]) : 0
        let quarter = lag / 4 >= Self.subdivisionLag ? max(0, r[lag / 4]) : 0
        return (r[lag] + 0.5 * half + 0.25 * quarter) * prior
    }

    /// A kick pulls the beat phase toward itself when it lands near a beat.
    private func pullBeat() {
        let beat = stepPosition / 4
        var error = beat - beat.rounded()
        if error > 0.5 { error -= 1 }
        guard abs(error) < 0.3 else { return }
        stepPosition -= error * 4 * 0.35
    }

    /// Runs the clock from the first sound heard: at the default tempo until a lock, then at the measured one, so a
    /// tile's beat clock and travel move from the start as they do for the engine (which knows its tempo).
    private func advanceClock(dt: Double, resting: Bool) {
        guard heard, !resting else { return }
        stepPosition += dt / (60 / bpm / 4)
        lastStep = max(lastStep, Int(stepPosition.rounded(.down)))
    }

    // MARK: Energy and section

    private func updateEnergy(_ frame: SoundFrame, dt: Float, silent: Bool, resting: Bool) {
        if resting {
            energy = 0
            level = 0
            energySlow += (energy - energySlow) * min(1, dt / 2)
            return
        }
        var fromLoudness: Float = 0
        if !silent {
            let rms = frame.rmsDB
            if !heard {
                heard = true
                heardSince = lastTime
                loud = rms
                ceiling = rms
                floorDB = rms
            }
            loud += (rms - loud) * min(1, dt * (rms > loud ? 20 : 1))
            // The ceiling holds the loudest recent passage and falls slowly; the floor rises toward the quietest and
            // drops at once, so a steady passage reads as loud when it is the loudest heard and as quiet below one.
            ceiling = max(loud, ceiling - dt * 0.3)
            floorDB = min(loud, floorDB + dt)
            let span = max(ceiling - floorDB, 10)
            let relative = min(max((loud - (ceiling - span)) / span, 0), 1)
            // Half relative to the song's own range, half absolute: a quiet intro is the loudest thing heard so far,
            // and only an absolute scale says it is still quiet.
            let absolute = min(max((loud + 32) / 22, 0), 1)
            fromLoudness = 0.35 * relative + 0.65 * absolute
        }
        let fromDensity = min(density / 5, 1)
        let target: Float = silent ? 0 : 0.65 * fromLoudness + 0.35 * fromDensity
        energy += (target - energy) * min(1, dt * 3)
        energySlow += (energy - energySlow) * min(1, dt / 2)
        energyPeak = max(energy, energyPeak - dt * 0.02)
        level += (fromLoudness - level) * min(1, dt * 3)
        levelPeak = max(level, levelPeak - dt * 0.02)
        levelSlow += (level - levelSlow) * min(1, dt / 2)
    }

    private func updateSection(now: Double, resting: Bool) {
        if resting {
            if section != .intro {
                section = .intro
                sectionSince = now
            }
            highSince = -.infinity
            midSince = -.infinity
            lowSince = -.infinity
            return
        }
        // Loudness against the most the song has reached puts each moment in one of three tiers: a drop is held near
        // the peak, a build sits under it and a breakdown well below. The bars scale with the peak so a quiet song still
        // has drops and a loud one is not one long drop; the absolute floors keep a quiet intro out of a drop.
        let high = level >= max(0.55, levelPeak * 0.85)
        let low = level < max(0.25, levelPeak * 0.55)
        func hold(_ since: inout Double, _ active: Bool) -> Double {
            if !active {
                since = -.infinity
                return 0
            }
            if since == -.infinity { since = now }
            return now - since
        }
        let highFor = hold(&highSince, high)
        let midFor = hold(&midSince, !high && !low)
        let lowFor = hold(&lowSince, low)
        let inDrop = section == .drop || section == .drop2
        let dwell = now - sectionSince
        // A drop's loudness settles over its first bars; only a passage above that settled peak is a new drop.
        if inDrop, dwell < 2 { dropEntryPeak = max(dropEntryPeak, level) }
        var next = section
        // The first drop must rise out of what came before it (a loud build is the loudest thing heard so far and
        // would read as a drop within a second); a song that opens in its drop is called one after four seconds.
        let risen = now - heardSince >= 2 && level >= levelSlow * 1.15
        if !inDrop, highFor >= 0.4, dwell >= 1, dropsEntered > 0 || risen || highFor >= 4 {
            next = dropsEntered % 2 == 0 ? .drop : .drop2
        } else if inDrop, level >= dropEntryPeak * 1.12, highFor >= 0.4, dwell >= 2 {
            next = dropsEntered % 2 == 0 ? .drop : .drop2  // louder than the drop we are in: a new one
        } else if inDrop, lowFor >= 1, dwell >= 2 {
            next = .breakdown
        } else if inDrop, midFor >= 0.8, dwell >= 2 {
            next = .build
        } else if section == .build, lowFor >= 1.5, dwell >= 2 {
            next = .breakdown
        } else if section == .intro, highFor >= 1, dwell >= 1 {
            next = .build  // loud from the start but not yet risen: a build
        } else if section == .intro || section == .breakdown, midFor >= 1, level > 0.3, dwell >= 1.5 {
            next = .build
        }
        guard next != section else { return }
        if next == .drop || next == .drop2 {
            dropsEntered += 1
            dropEntryPeak = levelPeak
            counts.record(.impact)
        }
        section = next
        sectionSince = now
    }
}
