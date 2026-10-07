import Foundation

// How much each part of the band is written, apart from how loud it plays. A weight biases the choices the song writer
// already makes (where a part enters, which sections keep it, how busy its pattern is, how many fills and ghost notes
// it plays); it never pastes in a part the genre does not have, and it never touches a voice's gain. Neutral (every
// weight 1) writes today's song, bit for bit.

/// How much each part of the band is written: 0 never, 1 as the genre writes it, 2 as much as the genre allows.
///
/// Set it on a playing conductor with `DropConductor.setPartEmphasis(_:)`; it lands at the next phrase boundary.
/// ```swift
/// conductor.setPartEmphasis(PartEmphasis(drums: 1.6, guitar: 0.5))
/// ```
public struct PartEmphasis: Sendable, Hashable, Codable {
    /// The parts of the band a weight steers.
    public enum Part: String, Sendable, Hashable, Codable, CaseIterable {
        case drums, bass, keys, guitar, vocals, fx

        /// The part an instrument plays in.
        public init(_ instrument: Instrument) {
            switch instrument {
            case .kick, .snare, .hat, .openHat: self = .drums
            case .sub, .wobble, .bassGuitar: self = .bass
            case .keys: self = .keys
            case .acousticGuitar, .electricGuitar, .strum, .electricStrum: self = .guitar
            case .vox, .vocal, .vocalChop, .vocalSample: self = .vocals
            case .glitch, .scratch, .laser, .riser, .tapeStop, .impact, .cut: self = .fx
            }
        }
    }

    /// The range every weight is read in.
    public static let range: ClosedRange<Double> = 0...2
    /// Every part as the genre writes it: today's song.
    public static let neutral = PartEmphasis()

    public var drums: Double
    public var bass: Double
    public var keys: Double
    public var guitar: Double
    public var vocals: Double
    public var fx: Double

    /// Weights outside 0 ... 2 are clamped; a non-finite weight reads as 1.
    public init(
        drums: Double = 1, bass: Double = 1, keys: Double = 1, guitar: Double = 1, vocals: Double = 1, fx: Double = 1
    ) {
        self.drums = Self.clamp(drums)
        self.bass = Self.clamp(bass)
        self.keys = Self.clamp(keys)
        self.guitar = Self.clamp(guitar)
        self.vocals = Self.clamp(vocals)
        self.fx = Self.clamp(fx)
    }

    /// A part's weight, clamped to 0 ... 2.
    public subscript(part: Part) -> Double {
        get {
            switch part {
            case .drums: Self.clamp(drums)
            case .bass: Self.clamp(bass)
            case .keys: Self.clamp(keys)
            case .guitar: Self.clamp(guitar)
            case .vocals: Self.clamp(vocals)
            case .fx: Self.clamp(fx)
            }
        }
        set {
            let value = Self.clamp(newValue)
            switch part {
            case .drums: drums = value
            case .bass: bass = value
            case .keys: keys = value
            case .guitar: guitar = value
            case .vocals: vocals = value
            case .fx: fx = value
            }
        }
    }

    /// The weight of the part an instrument plays in.
    public func weight(for instrument: Instrument) -> Double { self[Part(instrument)] }

    /// Whether every part is written as the genre writes it.
    public var isNeutral: Bool { Part.allCases.allSatisfy { self[$0] == 1 } }

    /// Emphasis saved with fewer parts decodes the missing ones as 1.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys) throws -> Double { try container.decodeIfPresent(Double.self, forKey: key) ?? 1 }
        self.init(
            drums: try read(.drums), bass: try read(.bass), keys: try read(.keys), guitar: try read(.guitar),
            vocals: try read(.vocals), fx: try read(.fx))
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

// MARK: - The writer's side

extension PartEmphasis {
    /// How far above 1 a part is pushed, 0 ... 1.
    func lift(_ part: Part) -> Double { max(0, self[part] - 1) }

    /// Whether a part pushed above 1 takes an extra choice this time: true with probability `lift`, from a stable draw.
    func adds(_ part: Part, _ draw: Double) -> Bool { draw < lift(part) }

    /// Whether a part held below 1 sits out a whole stretch: an emphasised-down part enters later and drops out of more
    /// sections. Drops always keep a part that is written at all.
    static func sitsOut(
        weight: Double, section: SongSection, phraseInTrack: Int, barInPhrase: Int, barsPerPhrase: Int
    ) -> Bool {
        guard weight < 1 else { return false }
        if weight <= 0 { return true }
        switch section {
        case .intro:
            // Below 0.75 the intro goes without it; just below 1 it misses only the track's opening phrase.
            return weight < 0.75 || phraseInTrack == 0
        case .breakdown:
            return weight < 0.6
        case .build:
            // It enters part-way through the build: halfway at 0.5.
            return Double(barInPhrase) < (1 - weight) * Double(barsPerPhrase)
        case .drop, .drop2:
            return false
        }
    }

    /// Whether a note is the bones of its part's pattern (on a beat, played with weight), which thinning keeps.
    static func isAnchor(_ note: ScheduledNote, pos: Int?) -> Bool {
        guard let pos else { return false }
        return pos % 4 == 0 && note.velocity >= 0.3
    }

    /// The notes of one step with every weight below 1 applied: a part at 0 is gone, a part below 1 sits out the
    /// stretches `sitsOut` names and keeps each of its off-beat and ghost notes with probability `weight`. `draw` is a
    /// stable 0 ..< 1 number for a salt, the same for the same step whatever else changed.
    func thin(
        _ notes: inout [ScheduledNote], pos: Int?, section: SongSection, phraseInTrack: Int, barInPhrase: Int,
        barsPerPhrase: Int, draw: (UInt64) -> Double
    ) {
        notes.removeAll { note in
            let weight = self.weight(for: note.instrument)
            guard weight < 1 else { return false }
            if Self.sitsOut(
                weight: weight, section: section, phraseInTrack: phraseInTrack, barInPhrase: barInPhrase,
                barsPerPhrase: barsPerPhrase)
            {
                return true
            }
            if Self.isAnchor(note, pos: pos) { return false }
            let salt = StableHash.fnv1a(note.instrument.rawValue) ^ UInt64(truncatingIfNeeded: note.params.pitch ?? 0)
            return draw(salt) >= weight
        }
    }
}
