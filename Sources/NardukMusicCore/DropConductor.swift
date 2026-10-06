import Foundation

// The conductor, born as Wirewatcher's Network Dubstep (#45). Input never plays directly: signals feed an energy
// model, a character classifier and a cue queue; advance(throughStep:) turns that into notes on a 16th-note grid, with sections that only
// change on phrase boundaries. The music is a DJ set of tracks (Track.swift): each has its own key, tempo, hook,
// bass patch, groove and arrangement, lasts a few minutes, and hands over to the next at a phrase boundary; the
// input's character picks the next track and steers the current one. Pure, deterministic (seeded SplitMix64, FNV
// hashing), Sendable, and clock-free: the audio engine owns time and tells the conductor which step it needs next.
// Each Genre has its own arrangement (GenreArrangement.swift); changing genre while playing lands at the next bar
// line (see setGenre) and starts a new track in that genre.

// MARK: - Deterministic helpers

/// SplitMix64: tiny, fast and identical on every platform, so one seed always writes the same song.
public struct MusicRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0 ..< 1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

public enum StableHash {
    /// FNV-1a 64-bit over the UTF-8 bytes; unlike Hasher it is the same in every process.
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Energy

/// Log-scaled flow blended with the activity rate, smoothed, and normalised 0 ... 1 against a ceiling
/// that follows the busiest moment seen and relaxes slowly (so a gigabit LAN and a hotel Wi-Fi both get a full range).
/// A source that sends its own `level` bypasses the flow and keeps only the smoothing.
struct EnergyModel: Sendable {
    static let floorLog = 3.5  // ~3 KB/s reads as silence
    static let minCeilingLog = 7.0  // ~10 MB/s reads as full scale at least
    static let attack = 0.3
    static let release = 0.03

    private(set) var value = 0.0
    private(set) var inboundShare = 0.5
    private(set) var bytesPerSecond = 0.0
    private var ceilingLog = EnergyModel.minCeilingLog

    /// Drives the energy from a source's own 0 ... 1 level instead of the flow.
    mutating func update(level: Double) {
        let raw = min(1, max(0, level.isFinite ? level : 0))
        value += (raw - value) * (raw > value ? Self.attack : Self.release)
    }

    mutating func update(bytesIn: Double, bytesOut: Double, events: Double, seconds: Double) {
        let total = bytesIn + bytesOut
        bytesPerSecond = total / seconds
        if total > 0 { inboundShare += (bytesIn / total - inboundShare) * 0.1 }
        let level = log10(1 + bytesPerSecond)
        if level > ceilingLog {
            ceilingLog = level
        } else {
            ceilingLog = Self.minCeilingLog + (ceilingLog - Self.minCeilingLog) * 0.997
        }
        let throughput = min(1, max(0, (level - Self.floorLog) / (ceilingLog - Self.floorLog)))
        let activity = min(1, max(0, log10(1 + events / seconds) / log10(201)))
        // Events lift the energy of a busy-but-slow network, up to the drop threshold, never beyond it alone.
        let raw = throughput + (1 - throughput) * 0.4 * activity
        value += (raw - value) * (raw > value ? Self.attack : Self.release)
    }
}

// MARK: - Sections

extension SongSection {
    var isDrop: Bool { self == .drop || self == .drop2 }
}

/// INTRO -> BUILD -> DROP -> BREAKDOWN -> DROP2 -> ... Decides one bar before a phrase boundary and
/// applies at the boundary, so the arranger knows in the last bar whether a drop is coming. Energy and the
/// thresholds steer every move; the seed only varies lengths: a later build may take two phrases, DROP2 runs two
/// to four phrases before a one-phrase breather breakdown, and a breather sometimes rebuilds into a fresh DROP
/// (a double drop) instead of going straight back to DROP2.
struct SectionMachine: Sendable {
    private(set) var section: SongSection = .intro
    /// Phrases the current section has played, counting the one in progress.
    private(set) var phrasesInSection = 1
    private(set) var committedNext: SongSection?
    /// Phrases a build lasts at full energy; the first build is always one phrase.
    private(set) var buildLength = 1
    /// Phrases of DROP2 before a breather, from the track, applied when DROP2 starts.
    private(set) var drop2Length = 3
    private var plannedDrop2Length = 3
    private var builds = 0

    /// A new track: its own DROP2 length, and its first build is a single phrase again.
    mutating func startTrack(drop2Length: Int) {
        plannedDrop2Length = max(1, drop2Length)
        builds = 0
    }

    /// Replaces the decision for the next phrase (a track handing over goes to a build or the intro).
    mutating func override(_ next: SongSection) { committedNext = next }

    mutating func commit(energy: Double, build: Double, drop: Double, dropQueued: Bool, roll: UInt64 = 0) {
        var next: SongSection
        switch section {
        case .intro:
            next = energy >= build ? .build : .intro
        case .build:
            if energy >= build {
                next = phrasesInSection >= buildLength ? .drop : .build
            } else {
                next = energy < drop ? .breakdown : .build
            }
        case .drop:
            next = energy < drop ? .breakdown : (phrasesInSection >= 2 ? .drop2 : .drop)
        case .drop2:
            next = energy < drop || phrasesInSection >= drop2Length ? .breakdown : .drop2
        case .breakdown:
            if energy >= build {
                next = roll % 3 == 0 ? .build : .drop2
            } else if energy < drop, phrasesInSection >= 2 {
                next = .intro
            } else {
                next = .breakdown
            }
        }
        if dropQueued, !section.isDrop { next = Self.dropTarget(from: section) }
        committedNext = next
    }

    /// A queued drop wins over whatever was decided, as long as we are not already dropping.
    mutating func forceDrop() {
        guard !section.isDrop else { return }
        committedNext = Self.dropTarget(from: section)
    }

    /// Applies the committed decision. Returns true when the section changed.
    @discardableResult
    mutating func enterNext(roll: UInt64 = 0) -> Bool {
        defer { if section == .drop2, phrasesInSection == 1 { drop2Length = plannedDrop2Length } }
        let next = committedNext ?? section
        committedNext = nil
        if next == section {
            phrasesInSection += 1
            return false
        }
        section = next
        phrasesInSection = 1
        switch next {
        case .build:
            buildLength = builds == 0 ? 1 : 1 + Int(roll % 2)
            builds += 1
        default:
            break
        }
        return true
    }

    private static func dropTarget(from section: SongSection) -> SongSection {
        section == .breakdown ? .drop2 : .drop
    }
}

// MARK: - Quantizer

/// Holds events until they can land on a grid slot, and enforces how many of each instrument a bar may take.
struct Quantizer: Sendable {
    struct Pending: Sendable {
        var cue: MusicCue
        var pan: Double
        var age = 0
    }

    enum Budget: Hashable, Sendable {
        case instrument(Instrument)
        case ghostSnare, hatAccent, hatRoll, sparkle, lead
    }

    static let queueLimit = 256
    /// Steps an event may wait for an eligible slot before it is stale and dropped.
    static let maxAge = 32

    private(set) var queue: [Pending] = []
    private var barCounts: [Budget: Int] = [:]
    private var phraseCounts: [Budget: Int] = [:]
    private var lastVoxBar = Int.min / 2

    static func cap(_ budget: Budget) -> Int? {
        switch budget {
        case .instrument(let instrument): DropConductor.eventCaps[instrument]
        case .ghostSnare: 3
        case .hatAccent: 8
        case .hatRoll: 2
        case .sparkle: 2
        case .lead: DropConductor.leadNotesPerBar
        }
    }

    mutating func enqueue(_ event: Pending) {
        queue.append(event)
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
    }

    mutating func take() -> [Pending] {
        let items = queue
        queue.removeAll(keepingCapacity: true)
        return items
    }

    mutating func restore(_ items: [Pending]) { queue = items + queue }

    mutating func newBar() { barCounts.removeAll(keepingCapacity: true) }
    mutating func newPhrase() { phraseCounts.removeAll(keepingCapacity: true) }

    func canSpend(_ budget: Budget, bar: Int) -> Bool {
        if let cap = Self.cap(budget), barCounts[budget, default: 0] >= cap { return false }
        if budget == .instrument(.tapeStop), phraseCounts[budget, default: 0] >= 1 { return false }
        if budget == .instrument(.vox), bar - lastVoxBar < 2 { return false }
        return true
    }

    /// Structural notes (a breakdown lead) count against the bar's cap but leave the event spacing alone.
    mutating func spend(_ budget: Budget, bar: Int, structural: Bool = false) {
        barCounts[budget, default: 0] += 1
        phraseCounts[budget, default: 0] += 1
        if budget == .instrument(.vox), !structural { lastVoxBar = bar }
    }
}

// MARK: - Conductor

public struct DropConductor: Sendable {
    /// Instruments whose notes are bounded per bar, structural hits included. A flood of cues can't exceed these.
    public static let eventCaps: [Instrument: Int] = [
        .openHat: 2, .glitch: 3, .scratch: 2, .laser: 4, .vox: 3, .tapeStop: 1, .impact: 2,
    ]
    /// How many bass voices a track chooses between: every base patch (growl, reese, square wub, FM screech, talker,
    /// riddim) in each of its character variants.
    public static let bassVoiceCount = BassPatches.count * BassPatches.variantCount
    /// Vox notes a breakdown lead may play in one bar; the rest of the vox cap stays free for cues.
    static let leadNotesPerBar = 2

    /// How far left or right a directional cue sits (inbound left, outbound right, in Wirewatcher).
    public static let panWidth = 0.6
    private static let legendLimit = 8
    private static let maxEventNotesPerStep = 3

    public var settings: SongSettings {
        didSet {
            if settings.seed != oldValue.seed { rng = MusicRNG(seed: settings.seed) }
            // A tempo set from outside (the BPM control) becomes the centre later tracks vary around.
            if settings.bpm != oldValue.bpm, !settingTempo { baseBPM = settings.bpm }
        }
    }
    public private(set) var snapshot: ConductorSnapshot

    private var energy = EnergyModel()
    private var characterizer = FlowCharacterizer()
    private var sections = SectionMachine()
    private var quantizer = Quantizer()
    private var rng: MusicRNG
    private var nextStep = 0
    private var dropQueued = false

    /// The genre whose arrangement is playing. `settings.genre` is the one asked for; the two differ only
    /// between a request and the next bar line.
    public private(set) var activeGenre: Genre
    /// The most recent tempo change applied (a genre switch, or a new track at a new tempo), for the audio clock.
    public private(set) var lastSwitch: GenreSwitch?
    private var leadInFired = false
    /// Hat-roll notes already decided for steps that have not been processed yet (trap's DNS bursts).
    private var rollSteps: [Int: Double] = [:]

    // Flow accumulated since the last step
    private var accBytesIn = 0.0
    private var accBytesOut = 0.0
    private var accConnections = 0.0
    private var accErrors = 0.0
    private var appBytes: [String: Double] = [:]
    /// The source's own level, once a signal has set one; nil while the flow drives the energy.
    private var externalLevel: Double?

    // The set
    /// The track playing now.
    private(set) var track = Track()
    private var tracksStarted = 0
    /// Phrases the track has started (the current one included), and how many of them were drops.
    private var trackPhrases = 0
    private var trackDropPhrases = 0
    /// Once the hook has been heard the track is fixed; before that the first track may still be rewritten for the room.
    private var hookStated = false
    /// The current phrase is the track's last: its last bar plays the outro and the next phrase starts a new track.
    private var trackEnding = false
    private var trackStartStep = -1
    /// The tempo later tracks vary around: the session's, the genre's, or the one the user set.
    private var baseBPM: Double
    private var settingTempo = false

    // Arrangement state
    private var wobbleRate: WobbleRate = .quarter
    private var voice = 0
    private var plan = PhrasePlan()
    private var riserFired = false
    private var outroFired = false
    private var sectionJustStarted = false

    public init(settings: SongSettings) {
        self.settings = settings
        self.activeGenre = settings.genre
        self.rng = MusicRNG(seed: settings.seed)
        self.snapshot = ConductorSnapshot()
        self.baseBPM = settings.bpm
    }

    /// The genre that will take over at the next bar line, or nil when none is pending.
    public var pendingGenre: Genre? { settings.genre == activeGenre ? nil : settings.genre }

    /// What the input has sounded like lately (after hysteresis).
    public var character: MusicCharacter { characterizer.current }

    /// Asks for a genre change. Steps already emitted are never touched: a new track in the new genre, at the genre's
    /// default BPM (reported by `lastSwitch`), starts at the first bar line of steps not yet emitted, preceded by a
    /// short transition. Section and energy carry over. Setting `settings.genre` directly is equivalent.
    public mutating func setGenre(_ genre: Genre) { settings.genre = genre }

    // MARK: Input

    /// Feeds one signal. Its flow and cues are shared out over the steps up to the next `advance(throughStep:)`;
    /// its level, label and character hint hold until a later signal changes them.
    public mutating func ingest(_ signal: MusicSignal) {
        if let level = signal.level { externalLevel = level }
        if let label = signal.levelLabel { snapshot.levelLabel = label }
        if let hint = signal.character { characterizer.hint = hint }
        if let flow = signal.flow {
            accBytesIn += flow.inbound
            accBytesOut += flow.outbound
            accConnections += flow.starts
            accErrors += flow.faults
            for (source, amount) in flow.sources { appBytes[source, default: 0] += amount }
            if appBytes.count > 64 {
                let keep = appBytes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(32)
                appBytes = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
        }
        let pan = min(1, max(-1, signal.pan.isFinite ? signal.pan : 0))
        for cue in signal.cues { quantizer.enqueue(.init(cue: cue, pan: cue.pan ?? pan)) }
    }

    /// Hands the energy back to the flow model after a source has set its own `level`.
    public mutating func releaseLevel() {
        externalLevel = nil
        snapshot.levelLabel = nil
    }

    /// Goes back to classifying the flow after a source has pinned the character.
    public mutating func clearCharacterHint() { characterizer.hint = nil }

    /// Forces the next phrase boundary to land a drop (from INTRO, BUILD or BREAKDOWN; no-op while dropping).
    public mutating func queueDrop() {
        guard !sections.section.isDrop else { return }
        dropQueued = true
        trackEnding = false
        sections.forceDrop()
        snapshot.dropQueued = true
    }

    public mutating func setThresholds(build: Double, drop: Double) {
        let build = min(1, max(0, build))
        snapshot.buildThreshold = build
        snapshot.dropThreshold = min(build, min(1, max(0, drop)))
    }

    // MARK: Output

    /// Notes for every step not yet emitted up to and including `throughStep`. Each step is emitted once;
    /// calling again with the same (or an earlier) step returns nothing.
    public mutating func advance(throughStep: Int) -> [ScheduledNote] {
        guard throughStep >= nextStep else { return [] }
        let count = throughStep - nextStep + 1
        let share = Double(count)
        let bytesIn = accBytesIn / share
        let bytesOut = accBytesOut / share
        let connections = accConnections / share
        let errors = accErrors / share
        accBytesIn = 0
        accBytesOut = 0
        accConnections = 0
        accErrors = 0

        var notes: [ScheduledNote] = []
        for step in nextStep...throughStep {
            let seconds = settings.secondsPerStep
            if let externalLevel {
                energy.update(level: externalLevel)
            } else {
                energy.update(bytesIn: bytesIn, bytesOut: bytesOut, events: connections, seconds: seconds)
            }
            characterizer.observe(
                bytesIn: bytesIn, bytesOut: bytesOut, connections: connections, errors: errors, seconds: seconds)
            process(step: step, into: &notes)
        }
        nextStep = throughStep + 1
        snapshot.step = throughStep
        snapshot.section = sections.section
        snapshot.energy = energy.value
        snapshot.wobbleRate = wobbleRate
        snapshot.dropQueued = dropQueued
        snapshot.track = track.info
        return notes
    }

    // MARK: Per-step arrangement

    private mutating func process(step: Int, into notes: inout [ScheduledNote]) {
        let perBar = max(4, settings.stepsPerBar)
        let perPhrase = max(perBar, settings.stepsPerPhrase)
        let bar = step / perBar
        let barStep = step % perBar
        let phraseStep = step % perPhrase

        // A pending genre lands here and only here: the first bar line of steps not yet emitted.
        let switched = barStep == 0 && applyPendingGenre(step: step)
        if tracksStarted == 0 { startTrack(step: step, reason: .first) }
        if barStep == 0 { startBar() }
        if phraseStep == 0 {
            if step > 0 {
                sectionJustStarted = sections.enterNext(roll: rng.next())
                if sections.section.isDrop { dropQueued = false }
                if trackEnding {
                    startTrack(step: step, reason: .next)
                } else if !hookStated, characterizer.current != track.character {
                    // The first record is picked after hearing the room: rewrite it before its hook has played.
                    startTrack(step: step, reason: .rewrite)
                }
            }
            trackPhrases += 1
            if sections.section.isDrop { trackDropPhrases += 1 }
            quantizer.newPhrase()
            plan = PhrasePlanner.plan(
                track: track, section: sections.section, phraseInTrack: trackPhrases - 1,
                live: characterizer.current, roll: rng.next())
            riserFired = false
            outroFired = false
            applySectionSound()
            if sections.section != .intro || trackPhrases >= 2 { hookStated = true }
        }
        if dropQueued { sections.forceDrop() }
        if phraseStep == perPhrase - perBar {
            sections.commit(
                energy: energy.value, build: snapshot.buildThreshold, drop: snapshot.dropThreshold,
                dropQueued: dropQueued, roll: rng.next())
            trackEnding = shouldEndTrack()
            if trackEnding {
                sections.override(energy.value >= snapshot.dropThreshold ? .build : .intro)
                note(legend: "next track ← \(characterizer.current.label)", replacingPrefix: "next track")
            }
        }
        let inLastBar = phraseStep >= perPhrase - perBar
        let dropComing = inLastBar && !sections.section.isDrop && sections.committedNext?.isDrop == true
        let outro: Outro? = trackEnding && inLastBar ? (sections.section.isDrop ? track.outro : .filterSweep) : nil

        var stepNotes: [ScheduledNote] = []
        structure(
            step: step, bar: bar, barStep: barStep, perBar: perBar, perPhrase: perPhrase, phraseStep: phraseStep,
            dropComing: dropComing, outro: outro, switched: switched || trackStartStep == step, into: &stepNotes)
        leadIn(step: step, bar: bar, barStep: barStep, perBar: perBar, dropComing: dropComing, into: &stepNotes)
        if let velocity = rollSteps.removeValue(forKey: step) { merge(hat: velocity, step: step, into: &stepNotes) }
        place(into: &stepNotes, step: step, bar: bar, barStep: barStep, perBar: perBar)
        notes.append(contentsOf: stepNotes)
        sectionJustStarted = false
    }

    private mutating func startBar() {
        quantizer.newBar()
        for key in Array(appBytes.keys) { appBytes[key] = (appBytes[key] ?? 0) * 0.5 }
    }

    private var topApp: String? {
        appBytes.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    // MARK: The set

    private enum TrackStart {
        /// The session's first track.
        case first
        /// The first track rewritten for the input before its hook was heard.
        case rewrite
        /// The DJ flow moving on at a phrase boundary.
        case next
        /// A genre switch at a bar line.
        case genre
    }

    private mutating func startTrack(step: Int, reason: TrackStart) {
        let number = reason == .rewrite ? track.number : tracksStarted + 1
        let live = characterizer.current
        let bpm: Double =
            switch reason {
            case .first, .rewrite: settings.bpm
            case .genre: activeGenre.defaultBPM
            case .next:
                TrackGenerator.tempo(
                    base: baseBPM, genre: activeGenre, character: live, seed: settings.seed &+ UInt64(number))
            }
        let previous: Track? = reason == .next || reason == .genre ? track : nil
        track = TrackGenerator.make(
            number: number, genre: activeGenre, character: live, sessionSeed: settings.seed, bpm: bpm,
            topApp: topApp, previous: previous)
        tracksStarted = number
        if bpm != settings.bpm {
            setTempo(bpm)
            lastSwitch = GenreSwitch(genre: activeGenre, step: step, bpm: bpm)
        }
        sections.startTrack(drop2Length: track.drop2Length)
        trackEnding = false
        switch reason {
        case .first, .rewrite:
            trackPhrases = 0
            trackDropPhrases = 0
            hookStated = false
        case .next:
            trackPhrases = 0
            trackDropPhrases = 0
            hookStated = false
            trackStartStep = step
        case .genre:
            // Mid-phrase: the phrase in progress counts for the new track, and its hook starts right away.
            trackPhrases = 1
            trackDropPhrases = sections.section.isDrop ? 1 : 0
            hookStated = true
            trackStartStep = step
            plan = PhrasePlanner.plan(
                track: track, section: sections.section, phraseInTrack: 0, live: live, roll: rng.next())
            applySectionSound()
        }
        snapshot.track = track.info
        note(legend: "track ← \(track.name) · \(track.keyName) · \(track.character.label)", replacingPrefix: "track")
    }

    /// Whether the phrase now ending is the track's last. Decided one bar early, with the section decision.
    private func shouldEndTrack() -> Bool {
        guard !dropQueued, pendingGenre == nil else { return false }
        let section = sections.section
        if trackPhrases >= track.maxPhrases { return true }
        if trackDropPhrases >= track.dropBudget {
            // The track's drops are spent. Riding high energy, mix into the next track's build; once the energy has
            // fallen, the breakdown plays first and the hand-over follows it.
            if !section.isDrop { return sections.committedNext != .breakdown }
            if sections.committedNext?.isDrop == true || energy.value >= snapshot.dropThreshold { return true }
        }
        // The input changed: hand over once the track has had its say. A drop still riding high energy mixes straight
        // into the next track; one whose energy fell plays its breakdown first, and the hand-over follows it.
        guard characterizer.current != track.character, trackPhrases >= 3 else { return false }
        if section.isDrop { return trackDropPhrases >= 2 && sections.committedNext?.isDrop == true }
        return sections.committedNext?.isDrop != true
    }

    /// The wobble rate and bass patch change only where the section does: the drop plays the track's, DROP2 lifts the
    /// rate a rung and switches to the track's bigger patch.
    private mutating func applySectionSound() {
        let section = sections.section
        let rate = section == .drop2 ? track.liftRate : track.rate
        let patch = section == .drop2 ? track.bigVoice : track.voice
        if section.isDrop, rate != wobbleRate || patch != voice || sectionJustStarted, activeGenre != .trap {
            let name = BassPatches.names[patch % BassPatches.count]
            note(legend: "wobble ← \(rate.rawValue), \(name)", replacingPrefix: "wobble")
        }
        wobbleRate = rate
        voice = patch
    }

    private mutating func setTempo(_ bpm: Double) {
        settingTempo = true
        settings.bpm = bpm
        settingTempo = false
    }

    // MARK: Genre switching

    /// Makes the requested genre the active one at `step` (a bar line). Returns true when a transition should play.
    private mutating func applyPendingGenre(step: Int) -> Bool {
        guard let next = pendingGenre else { return false }
        activeGenre = next
        setTempo(next.defaultBPM)
        baseBPM = next.defaultBPM
        rollSteps.removeAll()
        leadInFired = false
        lastSwitch = GenreSwitch(genre: next, step: step, bpm: next.defaultBPM)
        // A genre chosen before the first step needs no transition.
        guard step > 0, tracksStarted > 0 else { return false }
        startTrack(step: step, reason: .genre)
        note(legend: "genre ← \(next.shortName), \(Int(next.defaultBPM)) BPM", replacingPrefix: "genre")
        return true
    }

    /// While a genre is pending, the rest of the bar before the switch carries a riser (or a tape stop in a
    /// drop) that ends exactly on the new bar line, where the impact lands.
    private mutating func leadIn(
        step: Int, bar: Int, barStep: Int, perBar: Int, dropComing: Bool, into out: inout [ScheduledNote]
    ) {
        guard pendingGenre != nil else {
            leadInFired = false
            return
        }
        let remaining = perBar - barStep
        guard !leadInFired, barStep != 0, !dropComing, remaining >= 4 else { return }
        leadInFired = true
        if sections.section.isDrop, quantizer.canSpend(.instrument(.tapeStop), bar: bar) {
            out.append(
                ScheduledNote(
                    step: step, instrument: .tapeStop,
                    velocity: 0.9, params: NoteParams(lengthSteps: remaining)))
            quantizer.spend(.instrument(.tapeStop), bar: bar)
            note(legend: "tape stop ← genre switch", replacingPrefix: "transition")
        } else {
            out.append(
                ScheduledNote(
                    step: step, instrument: .riser,
                    velocity: 0.8, params: NoteParams(pitch: track.keyRoot + 12, lengthSteps: remaining)))
            note(legend: "riser ← genre switch", replacingPrefix: "transition")
        }
    }

    private func merge(hat velocity: Double, step: Int, into out: inout [ScheduledNote]) {
        if let index = out.firstIndex(where: { $0.instrument == .hat }) {
            out[index].velocity = max(out[index].velocity, velocity)
        } else {
            out.append(ScheduledNote(step: step, instrument: .hat, velocity: min(1, velocity), params: NoteParams()))
        }
    }

    // MARK: The arrangement

    private mutating func structure(
        step: Int, bar: Int, barStep: Int, perBar: Int, perPhrase: Int, phraseStep: Int,
        dropComing: Bool, outro: Outro?, switched: Bool, into out: inout [ScheduledNote]
    ) {
        let half = perBar / 2
        let beat = max(1, perBar / 4)
        let barInPhrase = bar % max(1, settings.barsPerPhrase)
        let level = energy.value
        let section = sections.section
        let genre = activeGenre
        let profile = GenreArrangement.profile(genre)

        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams = NoteParams()) {
            out.append(
                ScheduledNote(step: step, instrument: instrument, velocity: min(1, max(0, velocity)), params: params))
        }

        if dropComing {
            // The last bar: a riser that ends exactly on the drop, and a snare roll that speeds up into it.
            if !riserFired {
                riserFired = true
                add(
                    .riser, profile.riserVelocity,
                    NoteParams(pitch: track.keyRoot + 12, lengthSteps: perPhrase - phraseStep))
                note(legend: "riser ← build to drop", replacingPrefix: "riser")
            }
            if Self.rolls(barStep: barStep, half: half, beat: beat) {
                add(.snare, (0.35 + 0.65 * Double(barStep) / Double(perBar)) * profile.gain)
            }
        }

        // The hand-over to the next track: a tape stop into the bar line, or a riser over a bridge or a closing filter.
        if let outro, !outroFired {
            if outro == .tapeStop, barStep >= half, quantizer.canSpend(.instrument(.tapeStop), bar: bar) {
                outroFired = true
                add(.tapeStop, 0.9, NoteParams(lengthSteps: perBar - barStep))
                quantizer.spend(.instrument(.tapeStop), bar: bar)
                note(legend: "tape stop ← next track", replacingPrefix: "transition")
            } else if outro != .tapeStop || barStep >= half {
                outroFired = true
                add(.riser, profile.riserVelocity, NoteParams(pitch: track.keyRoot + 12, lengthSteps: perBar - barStep))
                note(
                    legend: outro == .drumBridge ? "drum bridge ← next track" : "filter sweep ← next track",
                    replacingPrefix: "transition")
            }
        }

        if barStep == 0, switched || (section.isDrop && sectionJustStarted) {
            add(.impact, section.isDrop ? 1.0 : 0.85)
            quantizer.spend(.instrument(.impact), bar: bar)
        }

        let context = StepContext(
            step: step, bar: bar, barStep: barStep, perBar: perBar, barInPhrase: barInPhrase,
            barsPerPhrase: max(1, settings.barsPerPhrase), section: section, level: level,
            inboundShare: energy.inboundShare, track: track, plan: plan, wobbleRate: wobbleRate, voice: voice,
            dropComing: dropComing, outro: outro,
            introHook: section == .intro && trackPhrases >= 2)
        out += section.isDrop ? GenreArrangement.drop(genre, context) : GenreArrangement.bed(genre, context)
        for lead in GenreArrangement.lead(context)
        where quantizer.canSpend(.lead, bar: bar)
            && quantizer.canSpend(.instrument(.vox), bar: bar)
        {
            out.append(lead)
            quantizer.spend(.lead, bar: bar)
            quantizer.spend(.instrument(.vox), bar: bar, structural: true)
            if barStep == 0 { note(legend: "vox lead ← the hook", replacingPrefix: "vox lead") }
        }

        if profile.chops, level > 0.05 { chops(bar: bar, barStep: barStep, perBar: perBar, into: &out, step: step) }
    }

    /// Chill: a low-velocity vox chop every other bar.
    private mutating func chops(bar: Int, barStep: Int, perBar: Int, into out: inout [ScheduledNote], step: Int) {
        if barStep * 16 == 6 * perBar, bar % 2 == 0, quantizer.canSpend(.instrument(.vox), bar: bar) {
            out.append(
                ScheduledNote(
                    step: step, instrument: .vox, velocity: 0.3,
                    params: NoteParams(voice: (bar / 2 + track.vowel) % 4)))
            quantizer.spend(.instrument(.vox), bar: bar)
        }
    }

    private static func rolls(barStep: Int, half: Int, beat: Int) -> Bool {
        if barStep < half { return barStep % beat == 0 }
        if barStep < 3 * beat { return barStep % max(1, beat / 2) == 0 }
        return true
    }

    // MARK: Event placement

    private mutating func place(into stepNotes: inout [ScheduledNote], step: Int, bar: Int, barStep: Int, perBar: Int) {
        let pending = quantizer.take()
        guard !pending.isEmpty else { return }
        let half = perBar / 2
        let section = sections.section
        var survivors: [Quantizer.Pending] = []
        var used = Set(stepNotes.map(\.instrument))
        var placed = 0
        let tickBurst = pending.filter { $0.cue.gesture == .tick }.count >= 2

        for var item in pending {
            let outcome = placement(
                of: item, step: step, section: section, barStep: barStep, half: half, bar: bar,
                existing: stepNotes, used: used, placed: placed, tickBurst: tickBurst)
            switch outcome {
            case .discard:
                continue
            case .wait:
                item.age += 1
                if item.age <= Quantizer.maxAge { survivors.append(item) }
            case .place(let result):
                quantizer.spend(result.budget, bar: bar)
                if result.budget != .instrument(result.note.instrument) {
                    quantizer.spend(.instrument(result.note.instrument), bar: bar)
                }
                if let boost = result.boostHatIndex {
                    stepNotes[boost].velocity = max(stepNotes[boost].velocity, result.note.velocity)
                } else {
                    stepNotes.append(result.note)
                    used.insert(result.note.instrument)
                }
                for hit in result.roll {
                    rollSteps[step + hit.offset] = max(rollSteps[step + hit.offset] ?? 0, hit.velocity)
                }
                placed += 1
                note(legend: result.legend)
            }
        }
        quantizer.restore(survivors)
    }

    private struct Placement {
        var note: ScheduledNote
        var budget: Quantizer.Budget
        var legend: String
        var boostHatIndex: Int?
        var roll: [(offset: Int, velocity: Double)] = []
    }

    private enum Outcome {
        case discard
        case wait
        case place(Placement)
    }

    private mutating func placement(
        of item: Quantizer.Pending, step: Int, section: SongSection, barStep: Int, half: Int, bar: Int,
        existing: [ScheduledNote], used: Set<Instrument>, placed: Int, tickBurst: Bool
    ) -> Outcome {
        guard placed < Self.maxEventNotesPerStep else { return .wait }
        let pan = item.pan
        let cue = item.cue
        let calm = section == .intro || section == .breakdown
        let perBar = max(4, settings.stepsPerBar)
        let pos: Int? = (barStep * 16) % perBar == 0 ? barStep * 16 / perBar : nil
        let chordRoot = track.chord(bar % max(1, settings.barsPerPhrase))
        /// A chord tone of the bar's chord (root, third, fifth, seventh, ...) in semitones above the key, in the track's mode.
        func chordTone(_ index: Int) -> Int { track.mode.semitones(chordRoot + 2 * index) }

        func make(
            _ instrument: Instrument, _ velocity: Double, budget: Quantizer.Budget? = nil,
            params: NoteParams = NoteParams(pan: 0),
            legend: String
        ) -> Outcome {
            let budget = budget ?? .instrument(instrument)
            // Signature sounds wait for a musical slot: lasers on 8ths, scratches on the off-8ths, impacts and vox on
            // the beat, tape stops on beat 2 or 4, glitches on 8ths.
            if let pos, !Self.eligible(instrument, pos: pos) { return .wait }
            guard !used.contains(instrument), quantizer.canSpend(budget, bar: bar),
                quantizer.canSpend(.instrument(instrument), bar: bar)
            else { return .wait }
            var params = params
            params.pan = pan
            return .place(
                Placement(
                    note: ScheduledNote(step: step, instrument: instrument, velocity: min(1, velocity), params: params),
                    budget: budget, legend: legend))
        }

        switch cue.gesture {
        case .tick:
            guard quantizer.canSpend(.hatAccent, bar: bar) else { return .wait }
            if activeGenre == .trap, tickBurst, rollSteps[step + 1] == nil, quantizer.canSpend(.hatRoll, bar: bar) {
                // A burst of ticks rolls the hats: the first hit now, the rest on the steps that follow.
                quantizer.spend(.hatRoll, bar: bar)
                let roll = GenreArrangement.hatRoll(bar: bar, step: step)
                let legend = "hat roll ← \(cue.label) burst"
                if let index = existing.firstIndex(where: { $0.instrument == .hat }) {
                    var note = existing[index]
                    note.velocity = 0.95
                    return .place(
                        Placement(note: note, budget: .hatAccent, legend: legend, boostHatIndex: index, roll: roll))
                }
                let note = ScheduledNote(step: step, instrument: .hat, velocity: 0.6, params: NoteParams(pan: pan))
                return .place(Placement(note: note, budget: .hatAccent, legend: legend, roll: roll))
            }
            if rng.next() % 6 == 0, quantizer.canSpend(.instrument(.glitch), bar: bar), !used.contains(.glitch) {
                return make(.glitch, 0.6, legend: "glitch ← \(cue.label)")
            }
            if let index = existing.firstIndex(where: { $0.instrument == .hat }) {
                var note = existing[index]
                note.velocity = 0.95
                return .place(
                    Placement(note: note, budget: .hatAccent, legend: "hat accent ← \(cue.label)", boostHatIndex: index)
                )
            }
            return make(.hat, 0.85, budget: .hatAccent, legend: "hat accent ← \(cue.label)")
        case .stutter:
            return make(.glitch, 0.85, params: NoteParams(lengthSteps: 2), legend: "glitch stutter ← \(cue.label)")
        case .spark:
            let tone = Int(StableHash.fnv1a(cue.hashKey) % 4)
            let params = NoteParams(pitch: track.keyRoot + 12 + chordTone(tone), lengthSteps: 2)
            return make(.laser, 0.7, params: params, legend: "laser ← \(cue.label)")
        case .ghost:
            // Ghost notes live between the backbeats, never on a kick or the main snare.
            guard barStep != 0, barStep != half, !used.contains(.snare), !used.contains(.kick) else { return .wait }
            guard quantizer.canSpend(.ghostSnare, bar: bar) else { return .wait }
            return make(.snare, 0.22 + 0.16 * rng.unit(), budget: .ghostSnare, legend: "snare ghost ← \(cue.label)")
        case .impact:
            return make(.impact, 0.7, legend: "impact ← \(cue.label)")
        case .scratch:
            return make(.scratch, 0.7, legend: "scratch ← \(cue.label)")
        case .tapeStop:
            return make(.tapeStop, 0.8, params: NoteParams(lengthSteps: 4), legend: "tape stop ← \(cue.label)")
        case .zap:
            // Higher is a higher zap on the bar's chord: 1 tops the range, 0 bottoms it.
            let height = min(1, max(0, cue.height.flatMap { $0.isFinite ? $0 : nil } ?? 0))
            let tone = Int(height * 6.99)
            let params = NoteParams(pitch: track.keyRoot + 12 + chordTone(tone), lengthSteps: 1)
            return make(.laser, 0.6, params: params, legend: "laser ← \(cue.label)")
        case .sparkle:
            guard calm else { return .discard }
            guard quantizer.canSpend(.sparkle, bar: bar) else { return .wait }
            let tone = Int(rng.next() % 4)
            let params = NoteParams(pitch: track.keyRoot + 24 + chordTone(tone), lengthSteps: 1)
            return make(.laser, 0.25, budget: .sparkle, params: params, legend: "sparkle ← \(cue.label)")
        case .voice:
            let voice = cue.variant.map { max(0, $0) % 4 } ?? Int(StableHash.fnv1a(cue.hashKey) % 4)
            return make(.vox, 0.8, params: NoteParams(voice: voice), legend: "vox chop ← \(cue.label)")
        case .swell:
            let params = NoteParams(pitch: track.keyRoot + 12, lengthSteps: perBar)
            return make(.riser, 0.6, params: params, legend: "riser ← \(cue.label)")
        }
    }

    /// Whether a cue's instrument may land on this 16-step grid position.
    static func eligible(_ instrument: Instrument, pos: Int) -> Bool {
        switch instrument {
        case .laser, .glitch: pos % 2 == 0
        case .scratch: pos % 4 == 2
        case .impact, .vox: pos % 4 == 0
        case .tapeStop: pos == 4 || pos == 12
        default: true
        }
    }

    // MARK: Legend

    private mutating func note(legend text: String, replacingPrefix prefix: String? = nil) {
        if let prefix { snapshot.legend.removeAll { $0.hasPrefix(prefix) } }
        snapshot.legend.removeAll { $0 == text }
        snapshot.legend.append(text)
        if snapshot.legend.count > Self.legendLimit {
            snapshot.legend.removeFirst(snapshot.legend.count - Self.legendLimit)
        }
    }
}
