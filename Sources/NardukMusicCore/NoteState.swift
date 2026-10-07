// MARK: - Notes (what a music source knows about the pitches it plays)

/// A set of MIDI notes (0 ... 127) as a 128-bit mask: a fixed-size value, so building, copying and comparing one never
/// allocates.
public struct NoteSet: Sendable, Hashable {
    public static let noteCount = 128

    public var bits = SIMD2<UInt64>(repeating: 0)

    public init() {}

    public init(_ notes: some Sequence<Int>) {
        for note in notes { insert(note) }
    }

    public var isEmpty: Bool { bits == SIMD2<UInt64>(repeating: 0) }

    public var count: Int { bits[0].nonzeroBitCount + bits[1].nonzeroBitCount }

    public func contains(_ note: Int) -> Bool {
        guard note >= 0, note < NoteSet.noteCount else { return false }
        return bits[note >> 6] & (1 << UInt64(note & 63)) != 0
    }

    public mutating func insert(_ note: Int) {
        guard note >= 0, note < NoteSet.noteCount else { return }
        bits[note >> 6] |= 1 << UInt64(note & 63)
    }

    public mutating func remove(_ note: Int) {
        guard note >= 0, note < NoteSet.noteCount else { return }
        bits[note >> 6] &= ~(1 << UInt64(note & 63))
    }

    /// The pitch classes (0 = C ... 11 = B) of the notes in the set, one bit each.
    public var pitchClassMask: UInt16 {
        var mask: UInt16 = 0
        for note in 0..<NoteSet.noteCount where contains(note) { mask |= 1 << UInt16(note % 12) }
        return mask
    }

    /// True when any note in the set has pitch class `pitchClass` (any octave).
    public func containsPitchClass(_ pitchClass: Int) -> Bool {
        pitchClass >= 0 && pitchClass < 12 && pitchClassMask & (1 << UInt16(pitchClass)) != 0
    }
}

/// Per-note monotonic strike counters, the `HitCounters` pattern for pitches: the producer increments a note's lane on
/// every note-on; a consumer keeps the value it last saw and takes `delta(since:)`, so a short note between two polls
/// is still seen and a consumer that skips frames loses none. 8-bit lanes wrap; a consumer would have to skip 256
/// strikes of one note to miss a wrap.
public struct NoteCounters: Sendable, Hashable {
    public var low = SIMD64<UInt8>(repeating: 0)
    public var high = SIMD64<UInt8>(repeating: 0)

    public init() {}

    public subscript(note: Int) -> UInt8 {
        get {
            guard note >= 0, note < NoteSet.noteCount else { return 0 }
            return note < 64 ? low[note] : high[note - 64]
        }
        set {
            guard note >= 0, note < NoteSet.noteCount else { return }
            if note < 64 { low[note] = newValue } else { high[note - 64] = newValue }
        }
    }

    /// Records one note-on.
    public mutating func record(_ note: Int) {
        self[note] &+= 1
    }

    /// The notes struck since `previous`: every note whose counter moved.
    public func struck(since previous: NoteCounters) -> NoteSet {
        var out = NoteSet()
        let movedLow = low .!= previous.low
        let movedHigh = high .!= previous.high
        for note in 0..<64 {
            if movedLow[note] { out.insert(note) }
            if movedHigh[note] { out.insert(note + 64) }
        }
        return out
    }
}

/// Turns the notes a source schedules (a step and a length each) into what is sounding at a step position: the
/// producer calls `schedule` ahead of time and `advance(to:)` on its own clock. A fixed-capacity pool, so a steady
/// song never allocates; when the pool is full the oldest note is dropped.
public struct NoteTracker: Sendable {
    public static let capacity = 256

    /// The instruments whose notes have a pitch worth drawing.
    public static func isPitched(_ instrument: Instrument) -> Bool {
        switch instrument {
        case .wobble, .sub, .keys, .acousticGuitar, .electricGuitar, .bassGuitar, .vocal, .vocalChop, .vocalSample: true
        default: false
        }
    }

    private struct Entry: Sendable {
        var start: Double = 0
        var end: Double = 0
        var note: UInt8 = 0
        var begun = false
    }

    private var entries = [Entry](repeating: Entry(), count: NoteTracker.capacity)
    private var used = 0
    /// Notes sounding at the last `advance`.
    public private(set) var held = NoteSet()
    /// Note-ons seen so far (monotonic, wrapping); diff against the value a consumer last saw.
    public private(set) var counters = NoteCounters()

    public init() {}

    /// Queues a note that sounds from step `step` for `lengthSteps` steps.
    public mutating func schedule(step: Int, lengthSteps: Int, note: Int) {
        guard note >= 0, note < NoteSet.noteCount else { return }
        if used == NoteTracker.capacity {
            // Drop the entry that started earliest.
            var oldest = 0
            for i in 1..<used where entries[i].start < entries[oldest].start { oldest = i }
            used -= 1
            entries[oldest] = entries[used]
        }
        entries[used] = Entry(
            start: Double(step), end: Double(step + max(lengthSteps, 1)), note: UInt8(note), begun: false)
        used += 1
    }

    /// Queues `note` if it is a pitched note.
    public mutating func schedule(_ note: ScheduledNote) {
        guard NoteTracker.isPitched(note.instrument), let pitch = note.params.pitch else { return }
        schedule(step: note.step, lengthSteps: note.params.lengthSteps, note: pitch)
    }

    /// Moves to `position` (in 16th steps): starts the notes whose step has arrived, ends the ones whose length has
    /// passed, and refreshes `held`.
    public mutating func advance(to position: Double) {
        var heldNow = NoteSet()
        var i = 0
        while i < used {
            if !entries[i].begun, entries[i].start <= position {
                entries[i].begun = true
                counters.record(Int(entries[i].note))
            }
            if entries[i].begun {
                if position >= entries[i].end {
                    used -= 1
                    entries[i] = entries[used]
                    continue
                }
                heldNow.insert(Int(entries[i].note))
            }
            i += 1
        }
        held = heldNow
    }

    /// Releases everything, as when the source stops. The counters keep their values so a consumer's diff stays valid.
    public mutating func reset() {
        used = 0
        held = NoteSet()
    }
}
