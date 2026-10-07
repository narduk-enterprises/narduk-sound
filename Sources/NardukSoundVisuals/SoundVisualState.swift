import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// The latest sound, polled on the visualizer's own clock (docs/sound-contract.md section 3). `music` is nil when the
/// source is not music.
public struct SoundVisualInput: Sendable {
    public var frame: SoundFrame
    public var music: MusicContext?

    public init(frame: SoundFrame, music: MusicContext? = nil) {
        self.frame = frame
        self.music = music
    }
}

/// One particle in the hit FX field. Coordinates are normalized: 0 is the stage center and 1 is half the shorter side,
/// so every renderer scales them the same way.
public struct SoundParticle: Sendable {
    public enum Kind: UInt8, Sendable { case spark, ring, streak, block }

    public var x: Float = 0
    public var y: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var life: Float = 0
    public var maxLife: Float = 1
    public var size: Float = 1
    public var tint: Float = 0
    public var kind: Kind = .spark

    public init() {}

    public var age: Float { maxLife > 0 ? 1 - max(life, 0) / maxLife : 1 }
}

/// A fixed block of memory a `SoundVisualState` owns. Reading it through an `UnsafeBufferPointer` never retains or
/// copies, so a renderer holding a view cannot turn the next `update` into a copy-on-write allocation.
final class FixedBuffer<Element>: @unchecked Sendable {
    let count: Int
    private let base: UnsafeMutablePointer<Element>

    init(count: Int, repeating value: Element) {
        self.count = count
        base = UnsafeMutablePointer<Element>.allocate(capacity: max(count, 1))
        base.initialize(repeating: value, count: count)
    }

    deinit {
        base.deinitialize(count: count)
        base.deallocate()
    }

    var view: UnsafeBufferPointer<Element> { UnsafeBufferPointer(start: base, count: count) }
    var mutable: UnsafeMutablePointer<Element> { base }
}

/// The per-render-frame state every visualizer draws from: a beat clock interpolated between analysis frames, hit
/// envelopes, a smoothed spectrum with peak caps, a waveform history for phosphor trails, meters, instrument pads, the
/// palette blend and a fixed particle pool. Lifted from Wirewatcher's `DropVisualState`, with Data Beats'
/// `SpectrumCaps`, `PadState` and `MeterState` folded in.
///
/// `update` is idempotent per display frame, so the stage, the button and the meters can all call it. Every buffer is
/// allocated in `init`: the update path never allocates, and the buffers are exposed as `UnsafeBufferPointer` views
/// that stay valid for the life of the state. All time comes in as `now`, never from a clock, so an offline renderer
/// drives the same state.
@MainActor
public final class SoundVisualState {
    public static let bandCount = SoundFrame.spectrumCount
    public static let sampleCount = SoundFrame.waveformCount
    public static let historyDepth = 10
    public static let energyHistoryCount = 128
    /// Lanes in `padBrightness` (indexed by `Instrument.index`).
    public static let padCount = HitCounters.laneCount

    public let configuration: SoundVisualConfiguration
    private let palettes: any SoundPaletteProvider

    // Spectrum and waveform.
    private let spectrumStore = FixedBuffer<Float>(count: bandCount, repeating: 0)
    private let peaksStore = FixedBuffer<Float>(count: bandCount, repeating: 0)
    private let peakAge = FixedBuffer<Float>(count: bandCount, repeating: 0)
    private let waveformStore = FixedBuffer<Float>(count: sampleCount, repeating: 0)
    private let historyStore = FixedBuffer<Float>(count: sampleCount * historyDepth, repeating: 0)
    private let energyStore = FixedBuffer<Float>(count: energyHistoryCount, repeating: 0)
    private let sectionStore = FixedBuffer<UInt8>(count: energyHistoryCount, repeating: 0)
    private let padStore = FixedBuffer<Float>(count: padCount, repeating: 0)
    private let particleStore: FixedBuffer<SoundParticle>
    public var spectrum: UnsafeBufferPointer<Float> { spectrumStore.view }
    public var peaks: UnsafeBufferPointer<Float> { peaksStore.view }
    public var waveform: UnsafeBufferPointer<Float> { waveformStore.view }
    /// Ring of recent waveforms, `historyDepth` x `sampleCount`; newest at `historyHead`.
    public var history: UnsafeBufferPointer<Float> { historyStore.view }
    /// Conductor energy at each step, newest at `energyHead - 1`.
    public var energyHistory: UnsafeBufferPointer<Float> { energyStore.view }
    /// `SongSection.historyCode` (intro 0, build 1, drop 2, breakdown 3, drop2 4) at each step, parallel to `energyHistory`.
    public var sectionHistory: UnsafeBufferPointer<UInt8> { sectionStore.view }
    /// Decaying flash brightness per instrument, 0 ... 1, indexed by `Instrument.index`.
    public var padBrightness: UnsafeBufferPointer<Float> { padStore.view }
    public var particles: UnsafeBufferPointer<SoundParticle> { particleStore.view }
    public private(set) var historyHead = 0
    public private(set) var historyCount = 0
    public private(set) var energyHead = 0
    private var particleCursor = 0

    // Meters, 0 ... 1.
    public private(set) var peak: Double = 0
    public private(set) var rms: Double = 0
    public private(set) var peakHold: Double = 0
    private var holdTimer: Double = 0
    /// True when there is nothing to show: RMS below -100 dB and no band above 0.002.
    public private(set) var isSilent = true

    // Clock.
    public private(set) var time: Double = 0
    /// Continuous position in 16th steps, interpolated between analysis frames.
    public private(set) var stepPosition: Double = 0
    public private(set) var secondsPerStep: Double = 60.0 / 140 / 4
    public private(set) var stepsPerBar = 16
    public private(set) var fps: Double = 60
    public private(set) var isRunning = false

    // Envelopes 0 ... 1.
    public private(set) var kick: Float = 0
    public private(set) var snare: Float = 0
    public private(set) var hat: Float = 0
    public private(set) var glitch: Float = 0
    public private(set) var laser: Float = 0
    public private(set) var impact: Float = 0
    /// Bright full-stage flash. At most once per 0.4 s (< 3 Hz) and zero in calm mode.
    public private(set) var flash: Float = 0
    public private(set) var shake: Float = 0
    public private(set) var shakeOffset = SIMD2<Float>(0, 0)
    public private(set) var chroma: Float = 0

    // Music.
    public private(set) var wobbleCutoff: Float = 0
    public private(set) var wobblePhase: Float = 0
    public private(set) var energy: Float = 0
    public private(set) var level: Float = 0
    public private(set) var dropAmount: Float = 0
    public private(set) var travel: Double = 0
    public private(set) var section: SongSection = .intro
    public private(set) var phraseProgress: Float = 0
    public private(set) var buildThreshold: Float = 0
    public private(set) var dropThreshold: Float = 0
    public private(set) var dropQueued = false

    // Mood.
    /// Smoothed external drive, 0 ... 1.
    public private(set) var driveLevel: Float = 0
    /// How wild the stage is: the drive blended with the music's energy, toned down in calm mode.
    public private(set) var wild: Float = 0
    public private(set) var calm = false
    /// The palette after the drive-driven saturation.
    public private(set) var palette: SoundPalette
    private var basePalette: SoundPalette
    private var paletteFrom: SoundPalette
    private var paletteTo: SoundPalette
    private var paletteT: Float = 1
    private var paletteDuration: Float = 1
    private var centroid: Float = 0

    private var lastUpdate: Double = 0
    private var started = false
    private var lastSequence: UInt64 = 0
    private var lastStep = Int.min
    private var lastStepTime: Double = 0
    private var lastFlashTime: Double = -10
    private var lastChromaTime: Double = -10
    private var lastEnergyStep = Int.min
    private var lowBandPrevious: Float = 0
    private var lastHits = HitCounters()
    private var haveHits = false
    private var rng: UInt64

    public init(
        configuration: SoundVisualConfiguration = .wirewatcher,
        palettes: any SoundPaletteProvider = DefaultSoundPaletteProvider(),
        seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    ) {
        self.configuration = configuration
        self.palettes = palettes
        rng = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        particleStore = FixedBuffer(count: configuration.particleCapacity, repeating: SoundParticle())
        let initial = palettes.palette(for: .section(.intro))
        palette = initial
        basePalette = initial
        paletteFrom = initial
        paletteTo = initial
    }

    // The beat clock.
    public var beats: Double { stepPosition / 4 }
    public var beatPhase: Float { Float(beats - beats.rounded(.down)) }
    public var barPhase: Float {
        let bars = stepPosition / Double(max(stepsPerBar, 1))
        return Float(bars - bars.rounded(.down))
    }
    /// 1 on the beat, decaying through it: the universal "pulse on the beat" curve.
    public var beatPulse: Float { isRunning ? exp(-beatPhase * 5) : 0 }

    // MARK: Update

    /// Advances the state to `now` (seconds on any monotonic clock) from the latest `input`. A second call within 2 ms
    /// of the last one returns immediately.
    public func update(_ input: SoundVisualInput, now: Double, options: SoundVisualOptions = SoundVisualOptions()) {
        let elapsed = now - lastUpdate
        if started && elapsed < 0.002 { return }
        let dt = Float(started ? min(max(elapsed, 0), 0.1) : 1.0 / 60)
        if started && elapsed > 0 { fps += (1 / elapsed - fps) * 0.05 }
        // First frame, or back after the view was hidden: don't replay a backlog of hits.
        let stale = !started || elapsed > 0.5
        started = true
        lastUpdate = now
        time = now
        calm = options.calm

        let music = input.music
        let frame = input.frame

        let previousStepPosition = stepPosition
        advanceClock(music: music, now: now, dt: dt)
        let deltaBeats = Float(max(0, stepPosition - previousStepPosition) / 4)

        decayEnvelopes(dt)
        updatePads(dt)
        let isNewFrame = frame.sequence != lastSequence || lastSequence == 0
        if isNewFrame {
            lastSequence = frame.sequence
            ingest(frame, music: music, now: now, stale: stale)
        }
        if let music {
            energyStep(music)
        }
        smoothSpectrum(frame.spectrum, dt: dt)
        updateMeters(frame, dt: Double(dt))
        updateDrive(options.drive, dt: dt)
        updateSection(music: music, now: now)
        updateMotion(dt: dt, deltaBeats: deltaBeats, music: music)
        updateParticles(dt)
    }

    // MARK: Clock

    private func advanceClock(music: MusicContext?, now: Double, dt: Float) {
        guard let music else {
            // No music: the beat clock runs on wall time at the last known tempo; `beatPulse` stays 0.
            isRunning = false
            stepPosition += Double(dt) / max(secondsPerStep, 0.01)
            return
        }
        isRunning = music.isRunning
        secondsPerStep = music.secondsPerStep
        stepsPerBar = max(music.stepsPerBar, 1)
        phraseProgress = music.phraseProgress
        buildThreshold = music.buildThreshold
        dropThreshold = music.dropThreshold
        dropQueued = music.dropQueued
        if music.step != lastStep {
            if lastStep == Int.min || music.step < lastStep || music.step > lastStep + 8 {
                stepPosition = Double(music.step)  // first frame, a reset, or a seek
            }
            lastStep = music.step
            lastStepTime = now
        }
        let fraction = isRunning ? min((now - lastStepTime) / max(secondsPerStep, 0.01), 0.97) : 0
        stepPosition = max(stepPosition, Double(music.step) + fraction)
    }

    private func energyStep(_ music: MusicContext) {
        guard music.step != lastEnergyStep else { return }
        lastEnergyStep = music.step
        energyStore.mutable[energyHead] = music.energy
        sectionStore.mutable[energyHead] = music.section.historyCode
        energyHead = (energyHead + 1) % Self.energyHistoryCount
    }

    // MARK: Ingest

    private func ingest(_ frame: SoundFrame, music: MusicContext?, now: Double, stale: Bool) {
        let count = min(frame.waveform.count, Self.sampleCount)
        frame.waveform.withUnsafeBufferPointer { source in
            let target = waveformStore.mutable
            for i in 0..<count { target[i] = source[i] }
        }
        historyHead = (historyHead + 1) % Self.historyDepth
        let next = historyHead * Self.sampleCount
        let history = historyStore.mutable
        let waveform = waveformStore.view
        for i in 0..<count { history[next + i] = waveform[i] }
        historyCount = min(historyCount + 1, Self.historyDepth)

        level = max(0, min(1, (frame.rmsDB - configuration.levelFloorDB) / -configuration.levelFloorDB))
        isSilent = frame.rmsDB < -100 && maxBand(frame.spectrum) <= 0.002

        var sawKick = false
        if let music {
            wobbleCutoff = music.wobbleCutoff
            wobblePhase = music.wobblePhase
            if !haveHits || stale {
                // Nothing to diff against yet, or back after a long gap: adopt the counters without firing.
                lastHits = music.hitCounts
                haveHits = true
            } else {
                let delta = music.hitCounts.delta(since: lastHits)
                lastHits = music.hitCounts
                sawKick = fire(delta, now: now)
            }
        } else {
            wobbleCutoff = 0
            wobblePhase = 0
        }

        // Onset fallback on the low bands, for sources whose hit counters are sparse or absent.
        var low: Float = 0
        frame.spectrum.withUnsafeBufferPointer { bands in
            let n = min(6, bands.count)
            for i in 0..<n { low += bands[i] }
            if n > 0 { low /= Float(n) }
        }
        if !sawKick, low - lowBandPrevious > 0.28, kick < 0.3 { kick = 0.8 }
        lowBandPrevious = low
    }

    private func maxBand(_ bands: [Float]) -> Float {
        var best: Float = 0
        bands.withUnsafeBufferPointer { b in
            for i in 0..<b.count where b[i] > best { best = b[i] }
        }
        return best
    }

    /// Reacts to the hits in `delta`; returns whether a kick fired. A pad flashes once per instrument however many
    /// hits landed since the last frame.
    private func fire(_ delta: HitCounters, now: Double) -> Bool {
        var sawKick = false
        let pads = padStore.mutable
        if delta[.kick] > 0 {
            kick = 1
            sawKick = true
            spawnKick()
            // A busy stage shakes the camera on every kick.
            if !calm, wild > 0.6 { shake = max(shake, (wild - 0.6) * 0.9) }
        }
        if delta[.snare] > 0 {
            snare = 1
            spawnBurst(count: 22, speed: 1.1, life: 0.7, tint: 0.45)
            if !calm, now - lastChromaTime > 0.34 {
                chroma = 1
                lastChromaTime = now
            }
        }
        if delta[.hat] > 0 || delta[.openHat] > 0 {
            hat = max(hat, delta[.openHat] > 0 ? 1 : 0.6)
            if !calm { spawnTwinkle() }
        }
        if delta[.glitch] > 0 || delta[.scratch] > 0 {
            glitch = 1
            if !calm { spawnBlocks() }
        }
        if delta[.laser] > 0 {
            laser = 1
            if !calm { spawnStreaks() }
        }
        if delta[.impact] > 0 {
            impact = 1
            if !calm { shake = max(shake, 0.7) }
            spawnBurst(count: 48, speed: 1.8, life: 1.1, tint: 0.2)
        }
        for lane in 0..<Self.padCount where delta.lanes[lane] > 0 { pads[lane] = 1 }
        return sawKick
    }

    // MARK: Smoothing

    private func smoothSpectrum(_ target: [Float], dt: Float) {
        let attack = calm ? configuration.calmSpectrumAttack : configuration.spectrumAttack
        let release = calm ? configuration.calmSpectrumRelease : configuration.spectrumRelease
        let count = min(target.count, Self.bandCount)
        let spectrum = spectrumStore.mutable
        let peaks = peaksStore.mutable
        let age = peakAge.mutable
        var weighted: Float = 0
        var total: Float = 0
        target.withUnsafeBufferPointer { source in
            for i in 0..<count {
                let goal = min(max(source[i], 0), 1)
                var value = spectrum[i]
                value += (goal - value) * min(1, dt * (goal > value ? attack : release))
                spectrum[i] = value
                if value >= peaks[i] {
                    peaks[i] = value
                    age[i] = 0
                } else {
                    age[i] += dt
                    if age[i] > configuration.capHold { peaks[i] = max(value, peaks[i] - dt * configuration.capFall) }
                }
                weighted += Float(i) * goal
                total += goal
            }
        }
        if total > 0.001 {
            let measured = weighted / total / Float(max(Self.bandCount - 1, 1))
            centroid += (measured - centroid) * min(1, dt * 2)
        }
    }

    private func updateMeters(_ frame: SoundFrame, dt: Double) {
        func norm(_ db: Float) -> Double {
            min(1, max(0, (Double(db) - Double(configuration.meterFloorDB)) / -Double(configuration.meterFloorDB)))
        }
        let targetPeak = norm(frame.peakDB)
        let targetRMS = norm(frame.rmsDB)
        peak = targetPeak > peak ? targetPeak : max(targetPeak, peak - dt * configuration.meterPeakFall)
        rms = targetRMS > rms ? targetRMS : max(targetRMS, rms - dt * configuration.meterRMSFall)
        if peak >= peakHold {
            peakHold = peak
            holdTimer = configuration.meterHoldTime
        } else if holdTimer > 0 {
            holdTimer -= dt
        } else {
            peakHold = max(peak, peakHold - dt * configuration.meterHoldFall)
        }
    }

    private func updatePads(_ dt: Float) {
        let decay = exp(-dt * configuration.padDecay)
        let pads = padStore.mutable
        for lane in 0..<Self.padCount {
            let value = pads[lane] * decay
            pads[lane] = value < 0.003 ? 0 : value
        }
    }

    private func updateDrive(_ drive: Float?, dt: Float) {
        let blended: Float
        if let drive {
            let target = min(max(drive, 0), 1)
            driveLevel += (target - driveLevel) * min(1, dt * (target > driveLevel ? 4 : 1.2))
            blended = 0.65 * driveLevel + 0.35 * energy
        } else {
            driveLevel = 0
            blended = energy
        }
        wild = calm ? min(blended * 0.35, 0.3) : min(1, blended)
    }

    private func decayEnvelopes(_ dt: Float) {
        kick *= exp(-dt / 0.16)
        snare *= exp(-dt / 0.2)
        hat *= exp(-dt / 0.07)
        glitch *= exp(-dt / 0.14)
        laser *= exp(-dt / 0.3)
        impact *= exp(-dt / 0.6)
        flash *= exp(-dt / 0.16)
        shake *= exp(-dt / 0.32)
        chroma *= exp(-dt / 0.12)
        if calm {
            flash = 0
            shake = 0
            chroma = 0
            glitch = 0
        }
    }

    private func updateSection(music: MusicContext?, now: Double) {
        guard let music else {
            // No section: the palette follows the signal's spectral centroid instead.
            section = .intro
            basePalette = palettes.palette(for: .scalar(centroid))
            paletteT = 1
            return
        }
        let next = music.section
        if next != section {
            paletteFrom = basePalette
            paletteTo = palettes.palette(for: .section(next))
            paletteT = 0
            let isDrop = next == .drop || next == .drop2
            paletteDuration = isDrop && !calm ? 0.12 : 1.4
            if isDrop && !calm && now - lastFlashTime > 0.4 {
                flash = 0.9
                shake = 1
                lastFlashTime = now
            }
            section = next
        }
    }

    private func updateMotion(dt: Float, deltaBeats: Float, music: MusicContext?) {
        // Energy: the conductor's when there is one, else the signal's level.
        let target = music?.energy ?? level
        energy += (target - energy) * min(1, dt * (calm ? 1 : 3))
        let isDrop = music != nil && (section == .drop || section == .drop2)
        let dropGoal: Float = isDrop ? 1 : 0
        dropAmount += (dropGoal - dropAmount) * min(1, dt * (calm ? 1 : 4))

        if paletteT < 1 {
            paletteT = min(1, paletteT + dt / paletteDuration)
            let s = paletteT * paletteT * (3 - 2 * paletteT)
            basePalette = paletteFrom.mixed(with: paletteTo, s)
        }
        palette = basePalette.saturated(0.45 + 0.62 * wild)

        // Tunnel travel: one ring per beat at speed 1, a kick pushes forward.
        let speed: Float
        switch section {
        case .intro: speed = 0.35
        case .build: speed = 0.5 + 0.7 * phraseProgress
        case .drop: speed = 1.0
        case .breakdown: speed = 0.22
        case .drop2: speed = 1.25
        }
        let calmScale: Float = calm ? 0.4 : 1
        travel += Double(deltaBeats * speed * calmScale * (0.55 + 0.9 * wild) + (calm ? 0 : kick * dt * 0.9))
        if !isRunning { travel += Double(dt * 0.04) }

        if shake > 0.001 {
            let t = Float(time.truncatingRemainder(dividingBy: 3600))
            shakeOffset =
                SIMD2(sin(t * 71) + 0.5 * sin(t * 113), cos(t * 53) + 0.5 * cos(t * 97)) * shake * 0.018 * (0.5 + wild)
        } else {
            shakeOffset = .zero
        }
    }

    // MARK: Particles

    private func updateParticles(_ dt: Float) {
        let pool = particleStore.mutable
        let drag = pow(0.94, dt * 60)
        let streakDrag = pow(0.995, dt * 60)
        for i in 0..<particleStore.count where pool[i].life > 0 {
            pool[i].life -= dt
            pool[i].x += pool[i].vx * dt
            pool[i].y += pool[i].vy * dt
            let d = pool[i].kind == .streak ? streakDrag : drag
            pool[i].vx *= d
            pool[i].vy *= d
        }
    }

    private func emit(_ particle: SoundParticle) {
        particleStore.mutable[particleCursor] = particle
        particleCursor = (particleCursor + 1) % particleStore.count
    }

    private func random() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return Float(rng >> 40) / Float(1 << 24)
    }

    private func particle(
        x: Float = 0, y: Float = 0, vx: Float = 0, vy: Float = 0, life: Float, size: Float, tint: Float,
        kind: SoundParticle.Kind
    ) -> SoundParticle {
        var p = SoundParticle()
        p.x = x
        p.y = y
        p.vx = vx
        p.vy = vy
        p.life = life
        p.maxLife = life
        p.size = size
        p.tint = tint
        p.kind = kind
        return p
    }

    private func spawnKick() {
        emit(particle(life: 0.9, size: 1, tint: 0, kind: .ring))
        guard !calm else { return }
        spawnBurst(count: 14, speed: 0.9, life: 0.6, tint: 0.1)
    }

    private func spawnBurst(count: Int, speed: Float, life: Float, tint: Float) {
        guard !calm else { return }
        let scaled = max(2, Int(Float(count) * (0.4 + 1.6 * wild)))
        let speed = speed * (0.7 + 0.8 * wild)
        for _ in 0..<scaled {
            let angle = random() * 2 * .pi
            let v = speed * (0.35 + random())
            let r: Float = 0.3 + random() * 0.1
            var p = particle(
                x: cos(angle) * r, y: sin(angle) * r, vx: cos(angle) * v, vy: sin(angle) * v,
                life: life, size: 0.6 + random(), tint: tint + random() * 0.2, kind: .spark)
            p.life = life * (0.6 + 0.4 * random())
            emit(p)
        }
    }

    private func spawnTwinkle() {
        for _ in 0..<2 {
            let angle = random() * 2 * .pi
            let r: Float = 0.55 + random() * 0.5
            emit(particle(x: cos(angle) * r, y: sin(angle) * r, life: 0.25, size: 0.5, tint: 0.66, kind: .spark))
        }
    }

    private func spawnStreaks() {
        for _ in 0..<7 {
            let angle = random() * 2 * .pi
            let v: Float = 2.4 + random() * 1.4
            emit(
                particle(
                    x: cos(angle) * 0.2, y: sin(angle) * 0.2, vx: cos(angle) * v, vy: sin(angle) * v, life: 0.45,
                    size: 1, tint: 0.8, kind: .streak))
        }
    }

    private func spawnBlocks() {
        for _ in 0..<9 {
            emit(
                particle(
                    x: random() * 2.4 - 1.2, y: random() * 1.6 - 0.8, life: 0.2, size: 0.05 + random() * 0.3,
                    tint: random(), kind: .block))
        }
    }
}

extension SongSection {
    /// Stable small code for the section history ring (never renumbered).
    var historyCode: UInt8 {
        switch self {
        case .intro: 0
        case .build: 1
        case .drop: 2
        case .breakdown: 3
        case .drop2: 4
        }
    }
}
