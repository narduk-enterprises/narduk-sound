import Foundation
import NardukMusicCore
import NardukMusicDSP
import Synchronization

/// The one live pump from a song to the synth (narduk-sound#5; design in `docs/conductor-driver.md`).
///
/// It owns the cursor (the last song step written) and the look-ahead, feeds the conductor from a `ConductorSource`
/// and from `ingest(_:)`, and follows `DropConductor.lastSwitch`: the new tempo lands on the switch bar itself. Hand it
/// to `DropEngine.play(_:)`, which pumps it from a thread paced by the audio clock, so it keeps writing with the screen
/// off or the main thread busy. Song steps never go backwards: pause and resume carry on, a new synth after `stop()`
/// carries on from the next bar line, and only a new driver starts a new song.
///
/// Every method is safe from any thread; the state sits behind one lock that the render thread never takes.
public final class ConductorDriver: Sendable {
    /// The shortest look-ahead, the offline renderer's. The driver writes at least two IO buffers ahead as well.
    public static let lookaheadSeconds = 0.1

    /// Seconds of music written ahead of the render position, at the least.
    public let lookahead: Double
    private let state: Mutex<DriverState>

    /// Plays a `DropConductor` song. `source` feeds it before every write (an energy curve, a script, a data feed).
    public init(
        settings: SongSettings, source: (any ConductorSource)? = nil, lookahead: Double = lookaheadSeconds
    ) {
        self.lookahead = max(lookahead, 0.01)
        state = Mutex(DriverState(conductor: DropConductor(settings: settings), source: source, part: nil))
    }

    /// Plays a fixed part (the demo loop, a guitar part) through the same pump. There is no conductor: `next()` and the
    /// genre controls do nothing.
    public init(part: SongPart, lookahead: Double = lookaheadSeconds) {
        self.lookahead = max(lookahead, 0.01)
        state = Mutex(DriverState(conductor: DropConductor(settings: part.settings), source: nil, part: part))
    }

    /// The built-in eight-bar demo loop (`DemoPattern`), the song `DropEngine.playDemo()` plays.
    public static func demo() -> ConductorDriver { ConductorDriver(part: .demo) }

    // MARK: Controls

    /// Skips to a different genre, drawn from the seed's own stream (so the same seed skips the same way). It lands on
    /// the next bar line of steps not yet written, with its tempo. Returns the genre, nil when playing a fixed part.
    @discardableResult
    public func next() -> Genre? {
        state.withLock { state in
            guard state.part == nil else { return nil }
            let conductor = state.conductor
            let choices = Genre.allCases.filter { $0 != conductor.activeGenre && $0 != conductor.pendingGenre }
            guard !choices.isEmpty else { return nil }
            let genre = choices[Int(state.rng.next() % UInt64(choices.count))]
            state.conductor.setGenre(genre)
            state.status.pendingGenre = genre
            return genre
        }
    }

    /// Asks for `genre` from the next bar line of steps not yet written (see `DropConductor.setGenre`).
    public func setGenre(_ genre: Genre) {
        state.withLock { state in
            guard state.part == nil else { return }
            state.conductor.setGenre(genre)
            state.status.pendingGenre = state.conductor.pendingGenre
        }
    }

    /// Sets the tempo later tracks vary around; the synth takes it at its next bar line.
    public func setTempo(_ bpm: Double) {
        guard bpm.isFinite, bpm > 0 else { return }
        state.withLock { state in
            state.conductor.settings.bpm = bpm
            state.tempoRequest = bpm
            state.status.bpm = bpm
            state.status.before = nil
        }
    }

    /// Forces the next phrase boundary to land a drop.
    public func queueDrop() { state.withLock { $0.conductor.queueDrop() } }

    public func setThresholds(build: Double, drop: Double) {
        state.withLock { $0.conductor.setThresholds(build: build, drop: drop) }
    }

    /// Queues a signal that arrived on its own clock (a data feed); it reaches the conductor before the next write,
    /// after any queued earlier.
    public func ingest(_ signal: MusicSignal) { state.withLock { $0.pendingSignals.append(signal) } }

    /// Direct access to the conductor, under the driver's lock.
    public func withConductor<T: Sendable>(_ body: (inout DropConductor) -> T) -> T {
        state.withLock { body(&$0.conductor) }
    }

    // MARK: Reading

    /// What has been written so far (genre and tempo as written: up to a look-ahead before the listener hears them).
    public var status: ConductorStatus { state.withLock { $0.status } }

    /// The tempo a new synth should start at: the written tempo, or a pending genre's before the first step.
    public var startTempo: Double {
        state.withLock { state in
            if state.written < 0, state.part == nil, let pending = state.conductor.pendingGenre {
                return pending.defaultBPM
            }
            return state.status.bpm
        }
    }

    /// The song step of the current synth's step 0.
    var origin: Int { state.withLock { $0.origin } }

    // MARK: Pumping

    /// Writes every step up to the synth's render position plus the look-ahead into `core` and applies any tempo
    /// switch the write passed. Call it after each render (the engine's pump thread does). Returns the notes written.
    @discardableResult
    public func pump(_ core: DropSynthCore) -> Int {
        write(into: core) { core.schedule($0) }
    }

    /// `pump(_:)` with each note (its step moved to the synth's clock) handed to `emit` instead of scheduled.
    func write(into core: DropSynthCore, emit: (ScheduledNote) -> Void) -> Int {
        let ahead = max(lookahead, 2 * Double(core.lastBufferFrames) / core.sampleRate)
        return state.withLock { state in
            let identity = ObjectIdentifier(core)
            if state.core != identity {
                state.attach(core, identity: identity, aheadSeconds: ahead)
            }
            if let tempo = state.tempoRequest {
                state.tempoRequest = nil
                core.setTempo(tempo)
            }
            let position = core.renderedStepPosition + Double(state.origin)
            let through = Int(position + ahead / state.status.secondsPerStep)
            guard through > state.written else { return 0 }
            let notes = state.write(through: through)
            for var note in notes {
                note.step -= state.origin
                emit(note)
            }
            if let tempo = state.takeSwitchTempo() { core.setTempo(tempo) }
            return notes.count
        }
    }
}

/// What a `ConductorDriver` has written.
public struct ConductorStatus: Sendable {
    /// The genre playing (as written).
    public var genre: Genre
    /// The genre asked for that has not landed yet.
    public var pendingGenre: Genre?
    /// The synth's tempo (as written).
    public var bpm: Double
    public var stepsPerBar: Int
    public var section: SongSection = .intro
    /// The conductor's snapshot after the last write (energy, thresholds, a queued drop, the track and its key).
    public var snapshot = ConductorSnapshot()
    /// The last song step written, -1 before the first.
    public var written = -1
    /// The most recent tempo or genre switch the driver applied.
    public var lastSwitch: GenreSwitch?
    /// The genre and tempo before `lastSwitch`, for `heard(atStep:)`.
    var before: (genre: Genre, bpm: Double)?

    public var secondsPerStep: Double { 60 / max(bpm, 1) / 4 }

    /// The genre and tempo the listener hears at song step `step`: the previous ones until the switch step sounds.
    public func heard(atStep step: Int) -> (genre: Genre, bpm: Double) {
        if let before, let lastSwitch, step < lastSwitch.step { return before }
        return (genre, bpm)
    }
}

/// A fixed part a `ConductorDriver` can play instead of a conductor.
public struct SongPart: Sendable {
    /// Tempo and bar length (the genre is for display).
    public var settings: SongSettings
    /// Every note whose step is in the range.
    public var notes: @Sendable (ClosedRange<Int>) -> [ScheduledNote]
    /// The section at a step.
    public var section: @Sendable (Int) -> SongSection

    public init(
        settings: SongSettings, notes: @escaping @Sendable (ClosedRange<Int>) -> [ScheduledNote],
        section: @escaping @Sendable (Int) -> SongSection = { _ in .drop }
    ) {
        self.settings = settings
        self.notes = notes
        self.section = section
    }

    /// `DemoPattern`: a two-bar build into a six-bar wobble drop, looping every eight bars at 140 BPM.
    public static var demo: SongPart {
        SongPart(
            settings: SongSettings(bpm: 140, genre: .dubstep, stepsPerBar: DemoPattern.stepsPerBar),
            notes: { DemoPattern.notes(in: $0) }, section: { DemoPattern.section(atStep: $0) })
    }
}

/// The driver's state; every access holds the driver's lock.
struct DriverState {
    var conductor: DropConductor
    var source: (any ConductorSource)?
    let part: SongPart?
    var status: ConductorStatus
    var pendingSignals: [MusicSignal] = []
    var rng: MusicRNG
    /// The last song step written.
    var written = -1
    /// Seconds of music written, summed step by step so a tempo change never runs it backwards.
    var songTime = 0.0
    /// The song step of the current synth's step 0.
    var origin = 0
    var core: ObjectIdentifier?
    var tempoRequest: Double?
    private var appliedSwitch: GenreSwitch?
    private var pendingSwitchTempo: Double?

    init(conductor: DropConductor, source: (any ConductorSource)?, part: SongPart?) {
        self.conductor = conductor
        self.source = source
        self.part = part
        let settings = conductor.settings
        rng = MusicRNG(seed: settings.seed ^ 0x6E65_7874)  // "next": its own stream, apart from the conductor's
        status = ConductorStatus(
            genre: settings.genre, bpm: settings.bpm, stepsPerBar: max(settings.stepsPerBar, 1),
            section: part?.section(0) ?? .intro, snapshot: conductor.snapshot)
    }

    /// Maps a synth the driver has not written to onto the song: its first bar line not yet rendered or due (0 for a
    /// fresh synth) plays the song's next bar line. The conductor writes the rest of the current bar unheard.
    mutating func attach(_ core: DropSynthCore, identity: ObjectIdentifier, aheadSeconds: Double) {
        self.core = identity
        let bar = status.stepsPerBar
        func barLine(atOrAfter step: Int) -> Int { (step + bar - 1).floorDivided(by: bar) * bar }
        let coreBar: Int
        if core.renderedSampleCount == 0 {
            coreBar = 0
        } else {
            let due = core.renderedStepPosition + aheadSeconds / status.secondsPerStep
            coreBar = barLine(atOrAfter: Int(due.rounded(.up)) + 1)
        }
        let songBar = written < 0 ? 0 : barLine(atOrAfter: written + 1)
        if songBar - 1 > written { _ = write(through: songBar - 1) }
        origin = songBar - coreBar
        tempoRequest = written < 0 && part == nil ? conductor.pendingGenre?.defaultBPM ?? status.bpm : status.bpm
    }

    /// Writes every step after `written` through `through`, feeding the source first.
    mutating func write(through: Int) -> [ScheduledNote] {
        let first = written + 1
        guard through >= first else { return [] }
        written = through
        status.written = through
        if let part {
            status.section = part.section(through)
            return part.notes(first...through)
        }
        songTime += Double(through - first + 1) * conductor.settings.secondsPerStep
        for signal in pendingSignals { conductor.ingest(signal) }
        pendingSignals.removeAll(keepingCapacity: true)
        source?.feed(&conductor, time: songTime)
        var notes = conductor.advance(throughStep: through)
        source?.decorate(&notes, conductor: conductor)
        followSwitch()
        status.pendingGenre = conductor.pendingGenre
        status.section = conductor.snapshot.section
        status.snapshot = conductor.snapshot
        return notes
    }

    /// Records a switch the conductor wrote; its tempo goes to the synth at once (see `takeSwitchTempo`).
    private mutating func followSwitch() {
        guard let change = conductor.lastSwitch, change != appliedSwitch else { return }
        appliedSwitch = change
        status.before = (status.genre, status.bpm)
        status.lastSwitch = change
        status.genre = change.genre
        if change.bpm != status.bpm { pendingSwitchTempo = change.bpm }
        status.bpm = change.bpm
    }

    /// The tempo of a switch just written. The switch step is a bar line inside the look-ahead, so the synth is still
    /// rendering the bar before it, and `StepClock` lands the change on the switch bar exactly.
    mutating func takeSwitchTempo() -> Double? {
        defer { pendingSwitchTempo = nil }
        return pendingSwitchTempo
    }
}

extension Int {
    fileprivate func floorDivided(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
