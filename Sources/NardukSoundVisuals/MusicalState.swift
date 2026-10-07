import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// The pitch side of a `SoundVisualState`: a smoothed pitch-class vector (what the pitch-class wheel draws), a scrolling
/// note history (the piano roll), and a key estimate. It prefers what a music source says it plays (`MusicContext`'s
/// held notes) and falls back to the analysis chroma (`SoundFrame.chroma`), so the same visualizers work on a file or a
/// microphone. Every buffer is allocated in `init`; `update` never allocates.
@MainActor
public final class SoundMusicalState {
    /// Columns in the roll's history. With `rollSecondsPerColumn` this is the window the piano roll shows.
    public static let rollColumns = 96
    public static let rollSecondsPerColumn = 0.05
    public static let noteCount = NoteSet.noteCount
    public static let pitchClassCount = SoundFrame.chromaCount
    /// A column cell: a note that was struck in the column, or that is held through it.
    public static let onsetLevel: Float = 1
    public static let sustainLevel: Float = 0.55
    /// How long after the last note a source counts as "playing notes"; past it the wheel reads the analysis chroma.
    static let noteMemory = 2.0

    private let pitchClassStore = FixedBuffer<Float>(count: pitchClassCount, repeating: 0)
    private let rollStore = FixedBuffer<Float>(count: rollColumns * noteCount, repeating: 0)
    private let chromaRollStore = FixedBuffer<Float>(count: rollColumns * pitchClassCount, repeating: 0)
    private let profileStore = FixedBuffer<Float>(count: pitchClassCount, repeating: 0)

    /// How strongly each pitch class sounds, 0 ... 1 (index 0 = C ... 11 = B), smoothed.
    public var pitchClasses: UnsafeBufferPointer<Float> { pitchClassStore.view }
    /// The note history: `rollColumns` columns of `noteCount` cells (`column * noteCount + midiNote`); each cell is 0, `sustainLevel` or `onsetLevel`.
    /// The newest column is `rollHead`; columns older than `rollCount` are empty.
    public var roll: UnsafeBufferPointer<Float> { rollStore.view }
    /// The same history in 12 rows of pitch class (`column * pitchClassCount + pitchClass`), 0 ... 1, from `pitchClasses`.
    public var chromaRoll: UnsafeBufferPointer<Float> { chromaRollStore.view }
    public private(set) var rollHead = SoundMusicalState.rollColumns - 1
    public private(set) var rollCount = 0

    /// True while the source is telling the state its notes (a note struck or held within `noteMemory` seconds).
    public private(set) var hasNotes = false
    /// The lowest and highest note in the roll's window, for fitting the view; nil while it is empty.
    public private(set) var noteRange: ClosedRange<Int>?

    /// The key's tonic (0 = C ... 11 = B) and whether it is minor: the source's own when it gives one, else the
    /// best Krumhansl-Schmuckler match of the pitch classes heard over the last ~12 s. Nil until there is enough to say.
    public private(set) var keyPitchClass: Int?
    public private(set) var keyIsMinor = false
    /// 0 ... 1: how clearly one key stands out (1 when the source states it).
    public private(set) var keyConfidence: Float = 0

    private var lastNoteCounts = NoteCounters()
    private var haveCounts = false
    private var struckSinceColumn = NoteSet()
    private var lastNoteTime: Double = -100
    private var columnClock: Double = 0

    public init() {}

    /// Advances to the latest input. `dt` is the seconds since the last update (0 ... 0.1); `now` is the state's clock.
    func update(frame: SoundFrame, music: MusicContext?, now: Double, dt: Float, stale: Bool) {
        var held = NoteSet()
        if let music {
            held = music.heldNotes
            if !haveCounts || stale {
                lastNoteCounts = music.noteCounts
                haveCounts = true
            } else {
                let struck = music.noteCounts.struck(since: lastNoteCounts)
                lastNoteCounts = music.noteCounts
                if !struck.isEmpty {
                    struckSinceColumn.bits |= struck.bits
                    lastNoteTime = now
                }
            }
            if !held.isEmpty { lastNoteTime = now }
        } else {
            haveCounts = false
        }
        hasNotes = music != nil && now - lastNoteTime < SoundMusicalState.noteMemory

        smoothPitchClasses(frame: frame, held: held, dt: dt)
        advanceRoll(held: held, dt: dt)
        updateKey(music: music, dt: dt)
    }

    // MARK: Pitch classes

    private func smoothPitchClasses(frame: SoundFrame, held: NoteSet, dt: Float) {
        let attack = 1 - exp(-dt / 0.04)
        let release = 1 - exp(-dt / 0.25)
        let mask = held.pitchClassMask
        let chroma = frame.chroma
        let have = chroma.count >= SoundMusicalState.pitchClassCount
        for c in 0..<SoundMusicalState.pitchClassCount {
            let target: Float
            if hasNotes {
                target = mask & (1 << UInt16(c)) != 0 ? 1 : 0
            } else {
                target = have ? chroma[c] : 0
            }
            let previous = pitchClassStore.mutable[c]
            pitchClassStore.mutable[c] = previous + (target - previous) * (target > previous ? attack : release)
        }
    }

    // MARK: Roll

    private func advanceRoll(held: NoteSet, dt: Float) {
        columnClock += Double(dt)
        var pushed = 0
        while columnClock >= SoundMusicalState.rollSecondsPerColumn, pushed < 4 {
            columnClock -= SoundMusicalState.rollSecondsPerColumn
            pushColumn(held: held)
            pushed += 1
        }
        if columnClock >= SoundMusicalState.rollSecondsPerColumn { columnClock = 0 }
    }

    private func pushColumn(held: NoteSet) {
        let columns = SoundMusicalState.rollColumns
        rollHead = (rollHead + 1) % columns
        rollCount = min(rollCount + 1, columns)
        let notes = SoundMusicalState.noteCount
        let base = rollHead * notes
        let cells = rollStore.mutable
        var low = Int.max
        var high = Int.min
        for note in 0..<notes {
            let level: Float =
                struckSinceColumn.contains(note)
                ? SoundMusicalState.onsetLevel : (held.contains(note) ? SoundMusicalState.sustainLevel : 0)
            cells[base + note] = level
            if level > 0 {
                low = min(low, note)
                high = max(high, note)
            }
        }
        struckSinceColumn = NoteSet()
        let rows = SoundMusicalState.pitchClassCount
        for c in 0..<rows { chromaRollStore.mutable[rollHead * rows + c] = pitchClassStore.mutable[c] }
        recomputeRange(newest: low <= high ? low...high : nil)
    }

    /// The window's note range: the newest column's, widened by every older column's.
    private func recomputeRange(newest: ClosedRange<Int>?) {
        let notes = SoundMusicalState.noteCount
        var low = newest?.lowerBound ?? Int.max
        var high = newest?.upperBound ?? Int.min
        let cells = rollStore.view
        for age in 1..<max(rollCount, 1) {
            let column = (rollHead - age + SoundMusicalState.rollColumns) % SoundMusicalState.rollColumns
            let base = column * notes
            for note in 0..<notes where cells[base + note] > 0 {
                low = min(low, note)
                high = max(high, note)
            }
        }
        noteRange = low <= high ? low...high : nil
    }

    /// The column `age` steps back from the newest (0 is the newest); nil when it holds no history yet.
    public func column(age: Int) -> Int? {
        guard age >= 0, age < rollCount else { return nil }
        return (rollHead - age + SoundMusicalState.rollColumns) % SoundMusicalState.rollColumns
    }

    // MARK: Key

    /// Krumhansl-Kessler key profiles (tonic first), the standard probe tones for the key-finding correlation.
    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private func updateKey(music: MusicContext?, dt: Float) {
        // The long-term profile: pitch classes heard, forgotten over ~12 s.
        let decay = exp(-dt / 12)
        var mass: Float = 0
        for c in 0..<SoundMusicalState.pitchClassCount {
            profileStore.mutable[c] = profileStore.mutable[c] * decay + pitchClassStore.mutable[c] * dt
            mass += profileStore.mutable[c]
        }

        if let tonic = music?.keyPitchClass {
            keyPitchClass = tonic
            keyIsMinor = music?.keyIsMinor ?? estimatedMode(forTonic: tonic)
            keyConfidence = 1
            return
        }
        guard mass > 0.3 else {
            keyPitchClass = nil
            keyConfidence = 0
            return
        }
        var best = -Float.infinity
        var second = -Float.infinity
        var bestTonic = 0
        var bestMinor = false
        for tonic in 0..<12 {
            for mode in 0..<2 {
                let minor = mode == 1
                let score = correlation(tonic: tonic, minor: minor)
                if score > best {
                    second = best
                    best = score
                    bestTonic = tonic
                    bestMinor = minor
                } else if score > second {
                    second = score
                }
            }
        }
        keyPitchClass = bestTonic
        keyIsMinor = bestMinor
        // A clear key beats the runner-up by a margin; a flat spectrum (noise, a chromatic run) does not.
        keyConfidence = min(max((best - second) * 4, 0), 1) * min(max(best, 0), 1) * min(mass / 1.5, 1)
    }

    private func estimatedMode(forTonic tonic: Int) -> Bool {
        correlation(tonic: tonic, minor: true) > correlation(tonic: tonic, minor: false)
    }

    /// Pearson correlation of the long-term profile with a key profile rotated to `tonic`.
    private func correlation(tonic: Int, minor: Bool) -> Float {
        let n = SoundMusicalState.pitchClassCount
        let probe = minor ? SoundMusicalState.minorProfile : SoundMusicalState.majorProfile
        var meanX: Float = 0
        var meanY: Float = 0
        for i in 0..<n {
            meanX += profileStore.mutable[i]
            meanY += probe[i]
        }
        meanX /= Float(n)
        meanY /= Float(n)
        var cross: Float = 0
        var varX: Float = 0
        var varY: Float = 0
        for i in 0..<n {
            let x = profileStore.mutable[i] - meanX
            let y = probe[(i - tonic + n) % n] - meanY
            cross += x * y
            varX += x * x
            varY += y * y
        }
        let denominator = (varX * varY).squareRoot()
        return denominator > 1e-9 ? cross / denominator : 0
    }

    /// Names a pitch class: "C", "C♯", ...
    public static func name(ofPitchClass pitchClass: Int) -> String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][((pitchClass % 12) + 12) % 12]
    }
}
