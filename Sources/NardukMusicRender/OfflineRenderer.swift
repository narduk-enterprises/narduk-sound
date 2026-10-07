import Foundation
import NardukMusicCore
import NardukMusicDSP

/// The conductor and the synth on a virtual clock: no audio device, faster than real time, and deterministic.
///
/// It mirrors the real-time engine tick for tick (`NardukMusicEngine.DropEngine`): every 1/60 s it works out the step
/// the listener hears, asks the conductor for notes 100 ms ahead of the render position, follows tempo changes once
/// they are audible, then renders the tick's samples. So an offline render sounds like a live run of the same
/// signals, and the same seed and signals give the same samples, bit for bit.
public final class OfflineRenderer {
    /// Ticks per second of the virtual clock (the live engine's analysis and note-pump rate).
    public static let tickRate = 60.0
    /// How far ahead of the render position notes are scheduled (the live engine's look-ahead).
    public static let lookaheadSeconds = 0.1

    public let sampleRate: Double
    /// Frames rendered per tick.
    public let framesPerTick: Int
    public private(set) var settings: SongSettings
    public private(set) var conductor: DropConductor
    /// The conductor's snapshot with `step` set to the audible step, as a live UI reads it.
    public private(set) var snapshot: ConductorSnapshot
    /// The step the listener hears now (render position minus one buffer of latency).
    public private(set) var currentStep = 0
    /// Ticks rendered so far.
    public private(set) var tick = 0

    /// False stops the conductor's notes reaching the synth, so only `schedule`d notes sound.
    public let playsConductor: Bool

    /// Decides, note by note, whether a conductor note reaches the synth (nil lets every one through). It lets a render
    /// duck the song under a DROP the way the app does: the kick and bass in a build, the drums and bass in a drop.
    public var conductorNoteFilter: (@Sendable (ScheduledNote) -> Bool)?

    private let core: DropSynthCore
    private var directNotes: [ScheduledNote] = []
    private var scheduledThrough = -1
    private var appliedSwitchStep: Int?
    private var left: [Float]
    private var right: [Float]

    /// - Parameters:
    ///   - settings: tempo, genre, key and seed of the song.
    ///   - sampleRate: output rate; it must divide evenly into ticks (48 kHz gives 800 frames a tick).
    ///   - masterVolume: 0 ... 1, the live engine's default is 0.8.
    ///   - playsConductor: false keeps the conductor's notes out of the synth, so only `schedule`d notes sound.
    public init(
        settings: SongSettings = SongSettings(), sampleRate: Double = 48_000, masterVolume: Float = 0.8,
        playsConductor: Bool = true
    ) {
        self.settings = settings
        self.playsConductor = playsConductor
        self.sampleRate = sampleRate
        framesPerTick = Int(sampleRate / Self.tickRate)
        core = DropSynthCore(sampleRate: sampleRate, bpm: settings.bpm, stepsPerBar: settings.stepsPerBar)
        core.setMasterVolume(masterVolume)
        conductor = DropConductor(settings: settings)
        snapshot = conductor.snapshot
        left = [Float](repeating: 0, count: framesPerTick)
        right = [Float](repeating: 0, count: framesPerTick)
        pumpNotes()  // fill the first look-ahead window before the first render, as the live engine does
    }

    /// Seconds of song rendered so far.
    public var time: Double { Double(tick) / Self.tickRate }

    // MARK: Controls

    /// Asks for a new genre; it lands on the next bar line (see `DropConductor.setGenre`).
    public func setGenre(_ genre: Genre) {
        settings.genre = genre
        conductor.setGenre(genre)
        publishSnapshot()
    }

    /// Forces the next phrase boundary to land a drop.
    public func queueDrop() { conductor.queueDrop() }

    public func setThresholds(build: Double, drop: Double) { conductor.setThresholds(build: build, drop: drop) }

    /// Gives direct access to the conductor (for example to clear a character hint).
    /// Queues notes to play beside the conductor's (a scenario's `notes`). Each goes to the synth as its step comes
    /// within the look-ahead, as the conductor's notes do.
    public func setMasterFilter(_ filter: MasterFilter) { core.setMasterFilter(filter) }

    public func schedule(_ notes: [ScheduledNote]) {
        directNotes = (directNotes + notes).enumerated()
            .sorted { ($0.element.step, $0.offset) < ($1.element.step, $1.offset) }.map(\.element)
        pumpDirectNotes()
    }

    public func withConductor<T>(_ body: (inout DropConductor) -> T) -> T { body(&conductor) }

    // MARK: Rendering

    /// Runs one tick: feeds the signals that arrived in it, schedules notes, and renders `framesPerTick` stereo
    /// frames. The returned arrays are reused by the next call.
    public func advance(signals: [MusicSignal] = []) -> (left: [Float], right: [Float]) {
        for signal in signals { conductor.ingest(signal) }
        let latency = Double(core.lastBufferFrames) / core.sampleRate
        currentStep = Int(max(core.renderedStepPosition - latency / settings.secondsPerStep, 0))
        pumpNotes()
        publishSnapshot()
        let count = framesPerTick
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                core.render(frames: count, left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        tick += 1
        return (left, right)
    }

    /// The most recent `count` output samples (mono), oldest first, for analysis (`SpectrumAnalyzer`).
    public func copyRecentSamples(into buffer: UnsafeMutableBufferPointer<Float>) {
        core.copyRecentSamples(into: buffer)
    }

    /// Instruments that sounded since the previous call.
    public func takeHits() -> Set<Instrument> { core.takeHits() }

    private func pumpDirectNotes() {
        let through = Int(core.renderedStepPosition + Self.lookaheadSeconds / settings.secondsPerStep)
        var due = 0
        while due < directNotes.count, directNotes[due].step <= through { due += 1 }
        guard due > 0 else { return }
        for note in directNotes[..<due] { core.schedule(note) }
        directNotes.removeFirst(due)
    }

    private func pumpNotes() {
        let through = Int(core.renderedStepPosition + Self.lookaheadSeconds / settings.secondsPerStep)
        pumpDirectNotes()
        guard through > scheduledThrough else { return }
        let written = conductor.advance(throughStep: through)
        if playsConductor {
            for note in written where conductorNoteFilter?(note) ?? true { core.schedule(note) }
        }
        scheduledThrough = through
    }

    /// Follows a tempo change once its step is audible, as the live engine does, and publishes the snapshot.
    private func publishSnapshot() {
        if let change = conductor.lastSwitch, change.step != appliedSwitchStep, currentStep >= change.step {
            appliedSwitchStep = change.step
            settings.genre = change.genre
            if settings.bpm != change.bpm {
                settings.bpm = change.bpm
                core.setTempo(change.bpm)
            }
        }
        var next = conductor.snapshot
        next.step = currentStep
        snapshot = next
    }
}

/// A rendered stereo song.
public struct RenderedAudio: Sendable, Hashable {
    public var sampleRate: Double
    public var left: [Float]
    public var right: [Float]

    public init(sampleRate: Double, left: [Float], right: [Float]) {
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    public var frameCount: Int { left.count }
    public var seconds: Double { Double(frameCount) / sampleRate }

    /// The largest absolute sample on either channel.
    public var peak: Float {
        var peak: Float = 0
        for sample in left { peak = max(peak, abs(sample)) }
        for sample in right { peak = max(peak, abs(sample)) }
        return peak
    }

    /// FNV-1a 64 over every sample's bit pattern, left then right, little-endian: a fingerprint that changes when any
    /// sample does. The same seed and signals give the same value on the same platform; libm differs in the last
    /// bit between platforms, so a golden value is per platform.
    public var fingerprint: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ channel: [Float]) {
            for sample in channel {
                var bits = sample.bitPattern.littleEndian
                for _ in 0..<4 {
                    hash ^= UInt64(bits & 0xFF)
                    hash = hash &* 0x0000_0100_0000_01B3
                    bits >>= 8
                }
            }
        }
        mix(left)
        mix(right)
        return hash
    }
}
