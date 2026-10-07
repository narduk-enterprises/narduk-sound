import Foundation

// Songs for the DropConductor ("the MUSIC sounded the same"). Variety lives at the song level: the conductor plays a
// DJ set of generated tracks, and each track keeps its identity for a few minutes: a key and mode, a tempo, a
// signature two-bar hook that the build states and the drops repeat, one bass patch, one groove, one arrangement.
// Repetition inside a track is what makes the hook a hook; the next track (picked by the session seed and what the
// input sounds like) brings a different one. Everything is a pure function of (seed, track number, genre, input
// character), so a seed always writes the same set.

// MARK: - Harmony

/// The scale a track is written in. Every pitch the conductor emits is a scale degree of the track's mode.
enum Mode: Int, Sendable, Hashable, CaseIterable {
    case aeolian, dorian, phrygian, harmonicMinor
    case ionian, lydian, mixolydian

    var scale: [Int] {
        switch self {
        case .aeolian: [0, 2, 3, 5, 7, 8, 10]
        case .dorian: [0, 2, 3, 5, 7, 9, 10]
        case .phrygian: [0, 1, 3, 5, 7, 8, 10]
        case .harmonicMinor: [0, 2, 3, 5, 7, 8, 11]
        case .ionian: [0, 2, 4, 5, 7, 9, 11]
        case .lydian: [0, 2, 4, 6, 7, 9, 11]
        case .mixolydian: [0, 2, 4, 5, 7, 9, 10]
        }
    }

    var name: String {
        switch self {
        case .aeolian: "minor"
        case .dorian: "dorian"
        case .phrygian: "phrygian"
        case .harmonicMinor: "harmonic minor"
        case .ionian: "major"
        case .lydian: "lydian"
        case .mixolydian: "mixolydian"
        }
    }

    /// Semitones above the tonic for a scale degree; any integer, octaves carried (7 is the octave, -1 the 7th below).
    func semitones(_ degree: Int) -> Int {
        let octave = Int((Double(degree) / 7).rounded(.down))
        return scale[degree - 7 * octave] + 12 * octave
    }

    /// Whether the tonic triad has a major third.
    var isMajorQuality: Bool { scale[2] == 4 }

    /// Whether a semitone offset from the tonic is in the scale.
    func contains(semitones offset: Int) -> Bool { scale.contains(((offset % 12) + 12) % 12) }
}

// MARK: - Hook

/// One note of a two-bar hook: position on a 32-step grid, length in steps, scale degree above the bar's chord.
struct HookNote: Sendable, Hashable {
    var pos: Int
    var length: Int
    var degree: Int
    var accent: Bool
}

/// The signature riff of a track: two bars, repeated (transposed with the chords) through every drop.
struct Hook: Sendable, Hashable {
    var notes: [HookNote]

    /// The notes starting at a 32-step position.
    func notes(at pos: Int) -> [HookNote] { notes.filter { $0.pos == pos } }

    /// Rhythm and contour, independent of key: what makes two hooks sound like the same tune.
    var signature: Set<String> { Set(notes.map { "\($0.pos):\($0.degree)" }) }
    var rhythm: Set<Int> { Set(notes.map(\.pos)) }

    /// 0 (the same tune) ... 1 (nothing in common): Jaccard distance over (position, degree) and rhythm, averaged.
    func distance(to other: Hook) -> Double {
        func jaccard<T>(_ a: Set<T>, _ b: Set<T>) -> Double {
            let union = a.union(b).count
            return union == 0 ? 0 : 1 - Double(a.intersection(b).count) / Double(union)
        }
        return (jaccard(signature, other.signature) + jaccard(rhythm, other.rhythm)) / 2
    }

    /// "rising", "falling", "bouncing", "steady" or "arching", from the degrees.
    var contour: String {
        let degrees = notes.map(\.degree)
        guard let first = degrees.first, let last = degrees.last, let top = degrees.max() else { return "steady" }
        let turns = zip(zip(degrees, degrees.dropFirst()), degrees.dropFirst(2)).filter { pair, c in
            let (a, b) = pair
            return (b - a) * (c - b) < 0
        }.count
        if Set(degrees).count <= 2 { return "steady" }
        if turns >= 4 { return "bouncing" }
        if last - first >= 2 { return "rising" }
        if first - last >= 2 { return "falling" }
        return top > first + 2 ? "arching" : "rolling"
    }
}

/// Which statement of the hook a two-bar pair plays.
enum HookVariant: Int, Sendable, Hashable {
    /// The hook as written.
    case main
    /// Same first bar, second bar moved up a third: the answer to the hook's question.
    case answer
    /// Same first bar, an ending that lifts into the next phrase.
    case ending
}

/// How a track hands over to the next one, in the last bar of its last phrase.
enum Outro: Int, Sendable, Hashable {
    /// The whole mix winds down to a stop over the last two beats.
    case tapeStop
    /// The bass drops out: drums and a riser carry the last bar.
    case drumBridge
    /// A riser and a closing filter: the bass darkens and fades through the last bar.
    case filterSweep
}

// MARK: - Track

struct Track: Sendable, Hashable {
    var number = 1
    var genre: Genre = .dubstep
    var character: MusicCharacter = .idle
    var seed: UInt64 = 0
    /// MIDI tonic (60 ... 71); pitches fold into each voice's register.
    var keyRoot = 65
    var mode: Mode = .aeolian
    var bpm = 140.0
    var hook = Hook(notes: [HookNote(pos: 0, length: 16, degree: 0, accent: true)])
    var answer = Hook(notes: [HookNote(pos: 0, length: 16, degree: 0, accent: true)])
    var ending = Hook(notes: [HookNote(pos: 0, length: 16, degree: 0, accent: true)])
    /// Chord root per bar of a phrase, as scale degrees.
    var progression = [0, 0, 5, 5, 3, 3, 4, 4]
    /// The bass patch for the whole track, and the one DROP2 switches to (the big moment).
    var voice = 0
    var bigVoice = 0
    /// The keys timbre (0 bell, 1 stab, 2 electric piano, 3 pad).
    var keysVoice = 0
    var rate: WobbleRate = .quarter
    /// DROP2's wobble rate: at most one rung above the drop's.
    var liftRate: WobbleRate = .quarter
    var formant = 0.5
    var drive = 0.5
    var drums = 0
    var drums2 = 0
    /// Kits written for this song (narduk-libs#1617): the drop's, then DROP2's. Empty plays the bank's `drums`.
    var kits: [DrumVariant] = []
    /// 0 ... 1 per drum voice, 0.5 the standard one: this song's kick, snare and hat tuning.
    /// The drops play the backbeat at half time: one snare on 3, kicks thinned (narduk-libs#1617).
    var halfTime = false
    /// How the intro and the breakdown are staffed (narduk-libs#1617); 0 is the original bed.
    /// Intro: 1 keys first (no kick or hats, a louder pad), 2 drums first (kick every bar, hats from the start, no pad),
    /// 3 bass first (the sub from the first bar, no kick).
    var introStyle = 0
    /// Breakdown: 1 pad only (no drums), 2 heartbeat (a kick each bar, no hats, no pad), 3 hats only (8ths, no kick).
    var breakdownStyle = 0
    var kickTune = 0.5
    var snareTune = 0.5
    var hatTune = 0.5
    /// 0 ... 0.4 of a step the off-16ths sound late.
    var swing = 0.0
    var ghostDensity = 0.5
    /// The phrase-end fills this track alternates between.
    var fills: [Fill] = [.snareRoll, .kickDrop]
    var midFill: Fill?
    /// Phrases of DROP2 before a breather.
    var drop2Length = 2
    /// Drop phrases (DROP and DROP2) before the track hands over to the next.
    var dropBudget = 4
    /// A track never runs longer than this many phrases.
    var maxPhrases = 10
    var vowel = 0
    var outro: Outro = .drumBridge
    var name = "Untitled"

    /// The kit the song plays in a section.
    func kit(drop2: Bool) -> DrumVariant {
        if kits.count == 2 { return kits[drop2 ? 1 : 0] }
        let bank = Banks.drums(genre)
        return bank[(drop2 ? drums2 : drums) % bank.count]
    }

    /// The tune a drum hit carries, or nil for the standard voice.
    func drumTune(_ instrument: Instrument) -> Double? {
        let tune: Double =
            switch instrument {
            case .kick: kickTune
            case .snare: snareTune
            case .hat, .openHat: hatTune
            default: 0.5
            }
        return tune == 0.5 ? nil : tune
    }

    var keyName: String { "\(Self.noteNames[keyRoot % 12]) \(mode.name)" }

    var hookDescription: String {
        let carrier: String =
            switch genre {
            case .trap: "bell"
            case .house, .techno: "stab"
            case .chill, .ukGarage, .lofi: "keys"
            case .synthwave: "synth lead"
            case .drumAndBass: "reese"
            case .rock, .funk: "electric guitar"
            case .folk: "acoustic guitar"
            case .dubstep, .riddim: "wobble"
            }
        return "\(hook.contour) \(hook.notes.count)-note \(carrier) hook"
    }

    var info: TrackInfo {
        TrackInfo(number: number, name: name, key: keyName, bpm: bpm, character: character, hook: hookDescription)
    }

    static let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// The chord root (scale degree) of a bar of the phrase.
    func chord(_ barInPhrase: Int) -> Int {
        progression[((barInPhrase % progression.count) + progression.count) % progression.count]
    }

    /// A MIDI pitch: `base` (the tonic in some octave) plus a scale degree of the mode.
    func pitch(_ base: Int, degree: Int) -> Int { base + mode.semitones(degree) }

    func hook(_ variant: HookVariant) -> Hook {
        switch variant {
        case .main: hook
        case .answer: answer
        case .ending: ending
        }
    }

    /// Which statement each two-bar pair of a phrase plays. Drops repeat the hook and end on the lift; DROP2 answers
    /// it; the live input leans the pattern (a call trades question and answer, a download hammers the hook).
    func variants(section: SongSection, live: MusicCharacter) -> [HookVariant] {
        if genre == .riddim {
            return section == .drop2 ? [.main, .main, .main, .ending] : [.main, .main, .main, .main]
        }
        switch (section, live) {
        case (_, .surge): return [.main, .main, .main, .ending]
        case (_, .steady): return [.main, .answer, .main, .answer]
        case (.drop2, _): return [.main, .answer, .main, .ending]
        default: return [.main, .main, .main, .ending]
        }
    }
}

// MARK: - Generation

enum TrackGenerator {
    /// Writes a track. `bpm` is the tempo the track plays at (the conductor decides it); everything else comes from
    /// the session seed, the track number, the genre and the input character, steered away from `previous`.
    static func make(
        number: Int, genre: Genre, character: MusicCharacter, sessionSeed: UInt64, bpm: Double,
        topApp: String?, previous: Track?, mode pinned: Mode? = nil, variety: Double = 0
    ) -> Track {
        let seed =
            sessionSeed ^ (UInt64(truncatingIfNeeded: number) &* 0x9E37_79B9_7F4A_7C15)
            ^ StableHash.fnv1a(genre.rawValue + "/" + character.rawValue)
        var rng = MusicRNG(seed: seed)
        func pick(_ count: Int) -> Int { count > 1 ? Int(rng.next() % UInt64(count)) : 0 }
        func chance(_ p: Double) -> Bool { rng.unit() < p }

        var t = Track()
        t.number = number
        t.genre = genre
        t.character = character
        t.seed = seed
        t.bpm = bpm

        // Key and mode: a different tonic from the last track; the mode leans on the input.
        var tonic = pick(12)
        if let previous, tonic == previous.keyRoot % 12 { tonic = (tonic + 5) % 12 }
        t.keyRoot = 60 + tonic
        let modes = Self.modes(genre, character)
        t.mode = modes[pick(modes.count)]
        // A pinned mode replaces the pick after it is drawn, so every other choice of the track stays the same.
        if let pinned { t.mode = pinned }

        // Progression: two-bar chords suit a two-bar hook, so the hook lands whole on each chord.
        let progressions =
            t.mode.isMajorQuality && genre.family != .band ? Banks.majorProgressions : Banks.progressions(genre)
        var progression = pick(progressions.count)
        if let previous, progressions[progression] == previous.progression {
            progression = (progression + 1) % progressions.count
        }
        t.progression = progressions[progression]

        // The hook, and its two relatives.
        let rhythms = Banks.hookRhythms(genre)
        var rhythm = pick(rhythms.count)
        if let previous, previous.genre == genre, Self.rhythm(rhythms[rhythm]) == previous.hook.rhythm {
            rhythm = (rhythm + 1) % rhythms.count
        }
        t.hook = Self.hook(genre: genre, character: character, rhythm: rhythms[rhythm], rng: &rng)
        t.answer = Self.answer(to: t.hook, genre: genre)
        t.ending = Self.ending(of: t.hook, genre: genre)

        // Sound: one bass patch for the track (the top app picks its character variant), a bigger one for DROP2.
        let patches = Self.patches(genre)
        let base = patches[pick(patches.count)]
        let variant = Int((topApp.map(StableHash.fnv1a) ?? rng.next()) % UInt64(BassPatches.variantCount))
        t.voice = base + BassPatches.count * variant
        let bigBase =
            patches.count > 1
            ? patches[(patches.firstIndex(of: base)! + 1 + pick(patches.count - 1)) % patches.count] : base
        t.bigVoice =
            bigBase + BassPatches.count
            * ((variant + 1 + pick(BassPatches.variantCount - 1)) % BassPatches.variantCount)
        t.keysVoice = Self.keysVoice(genre)
        let ladder = Banks.rateLadder(genre)
        let rung = min(
            ladder.count - 1, max(0, Self.rateRung(genre, character, ladder: ladder) + (chance(0.3) ? 1 : 0)))
        t.rate = ladder[rung]
        t.liftRate = ladder[min(ladder.count - 1, rung + 1)]
        (t.formant, t.drive) = Self.timbre(genre, character)
        t.formant = min(1, max(0, t.formant + (rng.unit() - 0.5) * 0.3))
        t.vowel = pick(4)

        // Groove.
        let kits = Banks.drums(genre).count
        t.drums = pick(kits)
        t.drums2 = kits > 1 ? (t.drums + 1 + pick(kits - 1)) % kits : 0
        t.swing = Self.swing(genre, character)
        t.ghostDensity = character == .idle ? 0.25 : character == .chaos ? 0.9 : 0.4 + 0.4 * rng.unit()
        let fills = Self.fills(genre)
        let first = pick(fills.count)
        t.fills = [fills[first], fills[(first + 1 + pick(max(1, fills.count - 1))) % fills.count]]
        let mid = rng.unit()
        t.midFill = mid < 0.35 ? .kickDrop : mid < 0.7 ? .snareRoll : nil
        let outros = Self.outros(genre)
        t.outro = outros[pick(outros.count)]

        // Arrangement: how long the drops run before a breather, and how many drop phrases the track gets.
        switch character {
        case .idle:
            t.drop2Length = 1
            t.dropBudget = 3
        case .surge:
            t.drop2Length = 3
            t.dropBudget = 5
        case .chaos:
            t.drop2Length = 1 + pick(2)
            t.dropBudget = 3
        case .busy, .steady:
            t.drop2Length = 1 + pick(3)
            t.dropBudget = 2 + t.drop2Length + pick(2)
        }
        // Variety draws from streams of its own, after every banked draw, so variety 0 leaves the track untouched.
        Variety.apply(to: &t, variety: variety, previous: previous)
        t.name = name(t, topApp: topApp, rng: &rng)
        return t
    }

    /// Tempo for a track the DJ flow picks (not the first, nor one a genre switch starts): the base tempo nudged by
    /// the input and the seed, inside the genre's range.
    static func tempo(base: Double, genre: Genre, character: MusicCharacter, seed: UInt64) -> Double {
        let nudge: Double =
            switch character {
            case .idle: -4
            case .steady: -2
            case .busy: 1
            case .surge: 4
            case .chaos: 6
            }
        let jitter = Double(Int(seed % 5) - 2)
        let range = Self.tempoRange(genre)
        let target = min(range.upperBound, max(range.lowerBound, base + nudge + jitter))
        return min(base + 8, max(base - 8, target)).rounded()
    }

    static func tempoRange(_ genre: Genre) -> ClosedRange<Double> {
        switch genre {
        case .dubstep: 136...150
        case .riddim: 138...150
        case .drumAndBass: 168...178
        case .trap: 130...150
        case .house: 118...130
        case .chill: 78...96
        case .techno: 128...140
        case .ukGarage: 128...136
        case .synthwave: 100...118
        case .lofi: 72...90
        case .rock: 112...136
        case .folk: 84...108
        case .funk: 96...114
        }
    }

    // MARK: Genre and character tables

    static func modes(_ genre: Genre, _ character: MusicCharacter) -> [Mode] {
        switch (genre, character) {
        case (.techno, _): character == .chaos ? [.phrygian, .harmonicMinor] : [.aeolian, .phrygian, .aeolian]
        case (.ukGarage, _): [.dorian, .aeolian, .dorian]
        case (.synthwave, _): character == .chaos ? [.aeolian, .phrygian] : [.aeolian, .ionian, .aeolian, .mixolydian]
        case (.lofi, _): [.dorian, .aeolian, .mixolydian, .dorian]
        case (.rock, _): character == .chaos ? [.aeolian, .phrygian] : [.aeolian, .mixolydian, .dorian, .aeolian]
        case (.folk, _): [.ionian, .mixolydian, .aeolian, .ionian]
        case (.funk, _): [.dorian, .mixolydian, .dorian, .aeolian]
        case (.house, _), (.chill, _): character == .chaos ? [.aeolian, .phrygian] : [.dorian, .dorian, .aeolian]
        case (_, .chaos): [.phrygian, .harmonicMinor]
        case (_, .surge): [.phrygian, .aeolian]
        case (_, .idle): [.dorian, .aeolian]
        case (.trap, _): [.harmonicMinor, .aeolian, .phrygian]
        case (.riddim, _): [.phrygian, .aeolian]
        default: [.aeolian, .dorian, .harmonicMinor]
        }
    }

    static func patches(_ genre: Genre) -> [Int] {
        switch genre {
        case .dubstep: [0, 2, 3, 4]  // growl, square wub, FM screech, talker
        case .riddim: [5]
        case .drumAndBass: [1]  // reese
        case .trap: [0]  // (no wobble: the 808 carries the bass)
        case .house: [2, 4]
        case .chill: [4, 2]
        case .techno: [2]  // square wub, closed down to a pulse
        case .ukGarage: [4]  // talker
        case .synthwave: [1]  // reese, as a saw bass
        case .lofi: [2]  // soft square
        case .rock, .folk, .funk: [2]  // unused: the bass is a guitar
        }
    }

    static func keysVoice(_ genre: Genre) -> Int {
        switch genre {
        case .dubstep, .riddim, .trap: 0
        case .house, .techno: 1
        case .chill, .drumAndBass, .ukGarage, .synthwave, .lofi, .rock, .folk, .funk: 2
        }
    }

    static func rateRung(_ genre: Genre, _ character: MusicCharacter, ladder: [WobbleRate]) -> Int {
        let want: WobbleRate =
            switch (genre, character) {
            case (.dubstep, .idle), (.dubstep, .steady): .quarter
            case (.dubstep, .busy): .eighth
            case (.dubstep, .surge): .sixteenth
            case (.dubstep, .chaos): .eighthTriplet
            case (.riddim, .chaos): .sixteenthTriplet
            case (.riddim, _): .eighthTriplet
            case (.drumAndBass, .surge), (.drumAndBass, .chaos): .sixteenth
            case (.drumAndBass, _): .eighth
            case (.house, .surge): .sixteenth
            case (.house, _): .eighth
            case (.chill, _): .half
            case (.trap, _): .quarter
            case (.techno, .surge), (.techno, .chaos): .sixteenth
            case (.techno, _): .eighth
            case (.ukGarage, _): .eighth
            case (.synthwave, _): .quarter
            case (.lofi, _): .half
            case (.rock, _), (.folk, _), (.funk, _): .quarter
            }
        return ladder.firstIndex(of: want) ?? 0
    }

    static func timbre(_ genre: Genre, _ character: MusicCharacter) -> (formant: Double, drive: Double) {
        let formant: Double =
            switch character {
            case .idle: 0.6
            case .busy: 0.7
            case .steady: 0.5
            case .surge: 0.3
            case .chaos: 0.15
            }
        let lift: Double =
            switch character {
            case .idle: -0.15
            case .chaos: 0.2
            case .surge: 0.1
            default: 0
            }
        let base: (Double, Double) =
            switch genre {
            case .dubstep: (formant, 0.6)
            case .riddim: (0.15 + 0.4 * formant, 0.85)
            case .drumAndBass: (0.08 + 0.3 * formant, 0.65)
            case .trap: (0.5, 0.5)
            case .house: (0.35 + 0.4 * formant, 0.45)
            case .chill: (0.25 + 0.4 * formant, 0.25)
            case .techno: (0.2 + 0.3 * formant, 0.7)
            case .ukGarage: (0.3 + 0.35 * formant, 0.4)
            case .synthwave: (0.4 + 0.3 * formant, 0.5)
            case .lofi: (0.2 + 0.3 * formant, 0.2)
            case .rock: (0.5, 0.8)
            case .folk: (0.5, 0.05)
            case .funk: (0.5, 0.2)
            }
        return (base.0, min(1, max(0, base.1 + lift)))
    }

    static func swing(_ genre: Genre, _ character: MusicCharacter) -> Double {
        switch genre {
        case .chill: character == .chaos ? 0.2 : 0.3
        case .house: character == .busy || character == .idle ? 0.16 : 0.1
        case .drumAndBass: 0.06
        case .ukGarage: character == .chaos ? 0.25 : 0.32
        case .lofi: character == .chaos ? 0.25 : 0.36
        case .folk: 0.08
        case .funk: character == .chaos ? 0.2 : 0.14
        case .dubstep, .riddim, .trap, .techno, .synthwave, .rock: 0
        }
    }

    static func fills(_ genre: Genre) -> [Fill] {
        switch genre {
        case .dubstep: [.snareRoll, .halfTime, .bassStutter, .kickDrop, .tripletRoll]
        case .riddim: [.kickDrop, .snareRoll, .bassStutter]
        case .drumAndBass: [.snareRoll, .halfTime, .kickDrop, .tripletRoll]
        case .trap: [.tripletRoll, .kickDrop, .snareRoll]
        case .house: [.snareRoll, .kickDrop]
        case .chill: [.kickDrop, .halfTime]
        case .techno: [.snareRoll, .kickDrop, .bassStutter]
        case .ukGarage: [.snareRoll, .halfTime, .kickDrop]
        case .synthwave: [.snareRoll, .tripletRoll, .kickDrop]
        case .lofi: [.kickDrop, .halfTime]
        case .rock: [.snareRoll, .kickDrop, .tripletRoll]
        case .folk: [.kickDrop, .halfTime]
        case .funk: [.snareRoll, .kickDrop, .halfTime]
        }
    }

    static func outros(_ genre: Genre) -> [Outro] {
        switch genre {
        case .dubstep: [.tapeStop, .drumBridge, .filterSweep]
        case .riddim, .trap: [.tapeStop, .drumBridge]
        case .drumAndBass: [.drumBridge, .filterSweep]
        case .house: [.filterSweep, .drumBridge]
        case .chill: [.filterSweep]
        case .techno: [.filterSweep, .drumBridge]
        case .ukGarage: [.drumBridge, .filterSweep]
        case .synthwave: [.filterSweep, .tapeStop]
        case .lofi: [.tapeStop, .filterSweep]
        case .rock, .folk, .funk: [.drumBridge]
        }
    }

    // MARK: Hooks

    static func rhythm(_ flat: [Int]) -> Set<Int> { Set(stride(from: 0, to: flat.count - 1, by: 2).map { flat[$0] }) }

    /// Melodic steps (in scale degrees) a genre's hooks move by.
    static func steps(_ genre: Genre) -> [Int] {
        switch genre {
        case .dubstep: [-2, -1, 0, 1, 2, 3, 4, 7, -3]
        case .riddim: [0, 0, 0, 0, 7, -1, 3]
        case .drumAndBass: [-2, -1, 1, 2, 3, -3, 4]
        case .trap: [-2, -1, 1, 2, 4, -3, 1]
        case .house: [-1, 0, 1, 2, -2, 3]
        case .chill: [-1, 1, 2, -2, 3, 4, 1]
        case .techno: [0, 0, 0, 1, -1, 3, 0]
        case .ukGarage: [-1, 1, 2, -2, 3, 4, 1]
        case .synthwave: [-2, -1, 1, 2, 3, 4, -3]
        case .lofi: [-1, 1, -2, 2, 3, -3, 4]
        case .rock: [-1, 1, 2, -2, 3, 4, 0]
        case .folk: [-1, 1, -2, 2, 1, -1, 3]
        case .funk: [0, 0, 1, -1, 2, -2, 3]
        }
    }

    /// Writes a hook: a rhythm from the genre's bank, bent by the input, with a seeded contour.
    static func hook(genre: Genre, character: MusicCharacter, rhythm flat: [Int], rng: inout MusicRNG) -> Hook {
        var cells: [(pos: Int, length: Int)] = stride(from: 0, to: flat.count - 1, by: 2).map {
            (flat[$0], flat[$0 + 1])
        }
        switch character {
        case .idle:
            // Sparse: drop some weak notes, let the rest ring.
            let kept = cells.enumerated().filter { index, cell in
                index == 0 || cell.pos == 16 || rng.unit() > 0.35
            }.map(\.element)
            cells = kept.count >= 3 ? kept : Array(cells.prefix(3))
        case .busy:
            // Bouncy: split a long note into two.
            if let index = cells.indices.filter({ cells[$0].length >= 4 }).dropFirst(Int(rng.next() % 2)).first {
                let cell = cells[index]
                let half = cell.length / 2
                cells[index] = (cell.pos, half)
                cells.insert((cell.pos + half, cell.length - half), at: index + 1)
            }
        case .steady:
            // Question and answer: the second bar takes the first bar's rhythm.
            let first = cells.filter { $0.pos < 16 }
            cells = first + first.map { ($0.pos + 16, $0.length) }
        case .surge:
            break
        case .chaos:
            // Syncopated: push a couple of notes off the beat.
            for index in cells.indices where cells[index].pos % 16 != 0 && rng.unit() < 0.3 {
                let moved = cells[index].pos + 1
                if !cells.contains(where: { $0.pos == moved }), moved < 32 { cells[index].pos = moved }
            }
            cells.sort { $0.pos < $1.pos }
        }
        if character == .surge || genre == .drumAndBass {
            // Legato: every note runs into the next, so the bass glides and never lets go.
            for index in cells.indices {
                let next = index + 1 < cells.count ? cells[index + 1].pos : 32
                cells[index].length = max(1, next - cells[index].pos)
            }
        }
        for index in cells.indices {
            let next = index + 1 < cells.count ? cells[index + 1].pos : 32
            cells[index].length = max(1, min(cells[index].length, next - cells[index].pos))
        }

        // Contour: a seeded walk that starts on the chord root and comes back to the first bar's opening in bar two.
        let steps = Self.steps(genre)
        var degrees: [Int] = []
        var degree = 0
        for (index, cell) in cells.enumerated() {
            if index == 0 {
                degree = 0
            } else if cell.pos == 16 {
                degree = character == .steady ? 2 : 0
            } else {
                var step = steps[Int(rng.next() % UInt64(steps.count))]
                if character == .surge { step = abs(step) == 7 ? 1 : abs(step) }  // relentless: it climbs
                degree += step
                if degree > 9 || degree < -3 { degree = step > 0 ? degree - 7 : degree + 7 }
            }
            degrees.append(degree)
        }
        if character == .steady {
            // The answer bar echoes the question a third higher.
            let first = degrees.enumerated().filter { cells[$0.offset].pos < 16 }.map(\.element)
            for index in degrees.indices where cells[index].pos >= 16 {
                let source = index - first.count
                if source >= 0, source < first.count { degrees[index] = first[source] + 2 }
            }
        }
        // Make sure it moves: a hook that sits on one note is a drone (riddim excepted, which is meant to).
        if genre != .riddim, Set(degrees).count < 3, degrees.count >= 3 {
            degrees[degrees.count / 2] += 2
            degrees[degrees.count - 1] += 4
        }
        let top = degrees.max() ?? 0
        let notes = cells.enumerated().map { index, cell in
            HookNote(
                pos: cell.pos, length: cell.length, degree: degrees[index],
                accent: cell.pos % 16 == 0 || degrees[index] == top)
        }
        return Hook(notes: notes)
    }

    /// The answer: the first bar as written, the second a third higher (a third lower when already high).
    static func answer(to hook: Hook, genre: Genre) -> Hook {
        let shift = (hook.notes.map(\.degree).max() ?? 0) > 6 ? -2 : 2
        return Hook(
            notes: hook.notes.map { note in
                var note = note
                if note.pos >= 16 { note.degree += genre == .riddim ? 0 : shift }
                return note
            })
    }

    /// The ending: the last note lifts to the fifth (or the octave) and rings to the bar line.
    static func ending(of hook: Hook, genre: Genre) -> Hook {
        var notes = hook.notes
        guard let last = notes.indices.last else { return hook }
        notes[last].degree = notes[last].degree >= 4 ? 7 : 4
        notes[last].accent = true
        notes[last].length = 32 - notes[last].pos
        return Hook(notes: notes)
    }

    // MARK: Names

    static let nouns: [MusicCharacter: [String]] = [
        .idle: ["Lull", "Drift", "Hush", "Haze", "Standby", "Low Tide"],
        .busy: ["Hopscotch", "Tabs", "Scroll", "Bounce", "Hyperlink", "Window Shopping"],
        .steady: ["Conversation", "Callback", "Duet", "Echo", "Handshake", "Crosstalk"],
        .surge: ["Freight", "Torrent", "Pipeline", "Floodgate", "Long Haul", "Bulk"],
        .chaos: ["Meltdown", "Static", "Short Circuit", "Packet Storm", "Reset", "Timeout"],
    ]

    static func name(_ t: Track, topApp: String?, rng: inout MusicRNG) -> String {
        let pool = nouns[t.character] ?? ["Signal"]
        let noun = pool[Int(rng.next() % UInt64(pool.count))]
        if let word = topApp.flatMap(appWord) { return "\(word) \(noun)" }
        return "\(t.hook.contour.capitalized) \(noun)"
    }

    /// A readable word from a bundle ID: "com.apple.Safari" → "Safari", "us.zoom.xos" → "Zoom".
    static func appWord(_ bundleID: String) -> String? {
        let generic: Set<String> = [
            "com", "org", "net", "io", "us", "app", "apple", "client", "desktop", "helper", "mac", "macos",
            "xos", "osx", "agent", "daemon", "service", "beta",
        ]
        let parts = bundleID.split(separator: ".").map(String.init).filter {
            !generic.contains($0.lowercased()) && $0.count >= 3
        }
        guard let word = parts.last else { return nil }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
}
