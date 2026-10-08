import Foundation
import NardukMusicCore

/// Which of the conductor's notes carry the lead melody, and how pitches become scale degrees.
///
/// The conductor writes no "melody" channel: each genre carries the track's hook on its own instrument
/// (`GenreArrangement`): the wobble in dubstep, riddim and DnB drops, keys in trap, house, chill, techno, UK garage,
/// synthwave and lo-fi (and in every build), the lead guitar in rock, folk and funk, and vox in a breakdown. So the lead
/// is chosen bar by bar from a ranked list of carriers:
///
/// 1. a sung line: `vox` with a pitch, `vocal` in its `lead` style, `vocalSample`;
/// 2. a single-note guitar: `electricGuitar`, `acousticGuitar`;
/// 3. `keys`, except the pad patch (`voice` 3);
/// 4. `wobble`.
///
/// In each bar the best-ranked carrier with at least two onsets is the lead (else the best-ranked with any), and of a
/// chord on one step only its top note counts. A note a bar or longer is harmony (a pad, a held chord), never lead.
/// Drums, the sub, the bass guitar, the strums, choir and solo vocal pads and every effect are never lead.
public enum LeadLine {
    /// Notes this long (in steps) or longer are harmony.
    public static let harmonySteps = 16

    /// The carrier rank of a note, 0 best; nil when the note cannot be lead.
    public static func rank(_ note: ScheduledNote) -> Int? {
        guard note.params.pitch != nil, note.params.lengthSteps < harmonySteps else { return nil }
        switch note.instrument {
        case .vox, .vocalSample: return 0
        case .vocal: return VocalStyle(voice: note.params.voice ?? 0) == .lead ? 0 : nil
        case .electricGuitar, .acousticGuitar: return 1
        case .keys: return note.params.voice == 3 ? nil : 2
        case .wobble: return 3
        default: return nil
        }
    }

    /// One lead note: its step, MIDI pitch and the instrument that played it.
    public struct Note: Sendable, Hashable {
        public var step: Int
        public var pitch: Int
        public var instrument: Instrument
    }

    /// The lead line of one bar's notes, in step order.
    public static func line(ofBar notes: [ScheduledNote]) -> [Note] {
        var byRank: [Int: [ScheduledNote]] = [:]
        for note in notes {
            if let rank = rank(note) { byRank[rank, default: []].append(note) }
        }
        let onsets = byRank.mapValues { Set($0.map(\.step)).count }
        guard
            let chosen = onsets.keys.sorted().first(where: { onsets[$0, default: 0] >= 2 })
                ?? onsets.keys.min()
        else { return [] }
        var top: [Int: ScheduledNote] = [:]
        for note in byRank[chosen, default: []] {
            if let current = top[note.step], (current.params.pitch ?? 0) >= (note.params.pitch ?? 0) { continue }
            top[note.step] = note
        }
        return top.keys.sorted().compactMap { step in
            top[step].flatMap { note in
                note.params.pitch.map { Note(step: step, pitch: $0, instrument: note.instrument) }
            }
        }
    }

    // MARK: Scale degrees

    /// Semitones above a tonic to scale degree within the octave: the maximally even 7-of-12 map, round(s * 7 / 12).
    /// For a tonic of any diatonic mode but Lydian it sends the seven scale tones to seven different degrees.
    static let degreeOfSemitone = [0, 1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6]

    /// The scale degree of `pitch` (7 to the octave) above the tonic pitch class `tonic`.
    public static func degree(_ pitch: Int, tonic: Int) -> Int {
        let semitones = pitch - tonic
        let octave = semitones >= 0 ? semitones / 12 : -((11 - semitones) / 12)
        return octave * 7 + degreeOfSemitone[semitones - octave * 12]
    }

    /// The tonic pitch class (0 ... 11) under which `pitches` land on the fewest shared degrees: the key the notes
    /// fit, read from the notes themselves (the conductor's key is internal and changes with every track). Ties go to
    /// the lowest pitch class; for a diatonic set every tied tonic gives the same intervals.
    public static func tonic(of pitches: [Int]) -> Int {
        let classes = Set(pitches.map { (($0 % 12) + 12) % 12 })
        var best = (tonic: 0, collisions: Int.max)
        for tonic in 0..<12 {
            var seen = Set<Int>()
            var collisions = 0
            for pitchClass in classes where !seen.insert(degreeOfSemitone[(pitchClass - tonic + 12) % 12]).inserted {
                collisions += 1
            }
            if collisions < best.collisions { best = (tonic, collisions) }
        }
        return best.tonic
    }
}
