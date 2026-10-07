import Foundation

// Per-note processing for the sampled voice (narduk-libs#1641): one recorded singer becomes many parts because every
// note can carry its own expression, character, harmony detune and effects. `VocalExpression` packs into
// `NoteParams.expression`; the default (nothing set) packs to 0, which is a plain note, so existing songs are untouched.

/// A tempo-synced echo thrown from a note (the delay time is how many sixteenth steps between repeats).
public enum VocalThrow: String, Sendable, Hashable, Codable, CaseIterable {
    case off, dottedEighth, quarter, eighth

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Steps between repeats at the vocal echo.
    public var steps: Double {
        switch self {
        case .off, .dottedEighth: 6
        case .quarter: 4
        case .eighth: 2
        }
    }
}

/// What the voice is filtered through.
public enum VocalFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case none, telephone, radio, muffled

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct VocalExpression: Sendable, Hashable, Codable {
    /// 0 ... 1: how far the pitch swings in vibrato (1 is about ±0.7 semitone), and how fast (1 is about 8 Hz).
    public var vibratoDepth = 0.0
    public var vibratoRate = 0.5
    /// Semitones the note starts away from its pitch (-16 ... 15; negative scoops up from below, positive falls in
    /// from above) and how long it takes to arrive, 0 ... 1 (30 ... 250 ms).
    public var scoop = 0
    public var scoopTime = 0.3
    /// Semitones the pitch bends by the end of the note (-8 ... 7; negative is a fall, positive a rise), over the last
    /// `bendSpan` of it (0.15 / 0.3 / 0.6 / 1.0 of the note).
    public var bend = 0
    public var bendSpan = 0.15
    /// A second vowel the note morphs into across its length (crossfading the two recordings).
    public var morph: VocalVowel?
    /// -8 ... 7 steps of formant shift, about 1/16 octave each: negative is darker and deeper, positive younger and
    /// brighter. The voice is re-sung grain by grain at the note's own pitch, so the pitch does not move.
    public var formantShift = 0
    /// 0 ... 1 breath noise and saturation grit (the "power" feel on the real voice).
    public var breath = 0.0
    public var grit = 0.0
    /// Hard pitch snap, autotune style: no drift, no natural vibrato, the pitch exactly the note.
    public var snap = false
    /// -32 ... 28 cents of detune, in steps of 4 (the spread of a stacked choir).
    public var detune = 0
    /// A tempo-synced echo of this note, 0 ... 1 of the way to a full send.
    public var echo = VocalThrow.off
    public var echoSend = 0.5
    public var filter = VocalFilter.none
    /// The note sung backwards, swelling up to its end (a reverse swell into the next phrase).
    public var reverse = false
    /// Granular stretch: 0 plain, 1 four times slower, 2 ten times slower, 3 frozen. Pitch stays put.
    public var stretch = 0
    /// 0 ... 1 extra reverb that blooms across the note.
    public var swell = 0.0

    public init(
        vibratoDepth: Double = 0, vibratoRate: Double = 0.5, scoop: Int = 0, scoopTime: Double = 0.3, bend: Int = 0,
        bendSpan: Double = 0.15, morph: VocalVowel? = nil, formantShift: Int = 0, breath: Double = 0, grit: Double = 0,
        snap: Bool = false, detune: Int = 0, echo: VocalThrow = .off, echoSend: Double = 0.5,
        filter: VocalFilter = .none, reverse: Bool = false, stretch: Int = 0, swell: Double = 0
    ) {
        self.vibratoDepth = vibratoDepth
        self.vibratoRate = vibratoRate
        self.scoop = scoop
        self.scoopTime = scoopTime
        self.bend = bend
        self.bendSpan = bendSpan
        self.morph = morph
        self.formantShift = formantShift
        self.breath = breath
        self.grit = grit
        self.snap = snap
        self.detune = detune
        self.echo = echo
        self.echoSend = echoSend
        self.filter = filter
        self.reverse = reverse
        self.stretch = stretch
        self.swell = swell
    }

    private enum CodingKeys: String, CodingKey {
        case preset, vibratoDepth, vibratoRate, scoop, scoopTime, bend, bendSpan, morph, formantShift, breath, grit
        case snap, detune, echo, echoSend, filter, reverse, stretch, swell
    }

    /// Every key is optional: `preset` names a starting point (`torch`, `power`, `robot`, `telephone`, `morphing`,
    /// `frozen`; default plain) and any other key overrides it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var x = VocalExpression()
        if let name = try c.decodeIfPresent(String.self, forKey: .preset) {
            guard let preset = VocalExpression.named(name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preset, in: c, debugDescription: "unknown expression preset \(name)")
            }
            x = preset
        }
        x.vibratoDepth = try c.decodeIfPresent(Double.self, forKey: .vibratoDepth) ?? x.vibratoDepth
        x.vibratoRate = try c.decodeIfPresent(Double.self, forKey: .vibratoRate) ?? x.vibratoRate
        x.scoop = try c.decodeIfPresent(Int.self, forKey: .scoop) ?? x.scoop
        x.scoopTime = try c.decodeIfPresent(Double.self, forKey: .scoopTime) ?? x.scoopTime
        x.bend = try c.decodeIfPresent(Int.self, forKey: .bend) ?? x.bend
        x.bendSpan = try c.decodeIfPresent(Double.self, forKey: .bendSpan) ?? x.bendSpan
        x.morph = try c.decodeIfPresent(VocalVowel.self, forKey: .morph) ?? x.morph
        x.formantShift = try c.decodeIfPresent(Int.self, forKey: .formantShift) ?? x.formantShift
        x.breath = try c.decodeIfPresent(Double.self, forKey: .breath) ?? x.breath
        x.grit = try c.decodeIfPresent(Double.self, forKey: .grit) ?? x.grit
        x.snap = try c.decodeIfPresent(Bool.self, forKey: .snap) ?? x.snap
        x.detune = try c.decodeIfPresent(Int.self, forKey: .detune) ?? x.detune
        x.echo = try c.decodeIfPresent(VocalThrow.self, forKey: .echo) ?? x.echo
        x.echoSend = try c.decodeIfPresent(Double.self, forKey: .echoSend) ?? x.echoSend
        x.filter = try c.decodeIfPresent(VocalFilter.self, forKey: .filter) ?? x.filter
        x.reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? x.reverse
        x.stretch = try c.decodeIfPresent(Int.self, forKey: .stretch) ?? x.stretch
        x.swell = try c.decodeIfPresent(Double.self, forKey: .swell) ?? x.swell
        self = x
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vibratoDepth, forKey: .vibratoDepth)
        try c.encode(vibratoRate, forKey: .vibratoRate)
        try c.encode(scoop, forKey: .scoop)
        try c.encode(scoopTime, forKey: .scoopTime)
        try c.encode(bend, forKey: .bend)
        try c.encode(bendSpan, forKey: .bendSpan)
        try c.encodeIfPresent(morph, forKey: .morph)
        try c.encode(formantShift, forKey: .formantShift)
        try c.encode(breath, forKey: .breath)
        try c.encode(grit, forKey: .grit)
        try c.encode(snap, forKey: .snap)
        try c.encode(detune, forKey: .detune)
        try c.encode(echo, forKey: .echo)
        try c.encode(echoSend, forKey: .echoSend)
        try c.encode(filter, forKey: .filter)
        try c.encode(reverse, forKey: .reverse)
        try c.encode(stretch, forKey: .stretch)
        try c.encode(swell, forKey: .swell)
    }

    public static func named(_ name: String) -> VocalExpression? {
        switch name {
        case "plain": .plain
        case "torch": .torch
        case "power": .power
        case "robot": .robot
        case "telephone": .telephone
        case "morphing": .morphing
        case "frozen": .frozen
        default: nil
        }
    }

    // MARK: Packing (bit layout shared with the render thread)

    private static func level(_ value: Double, _ steps: Int) -> Int {
        let v = value.isFinite ? value : 0
        return min(max(Int((v * Double(steps)).rounded()), 0), steps)
    }

    private static func signed(_ value: Int, bits: Int) -> Int {
        let half = 1 << (bits - 1)
        return min(max(value, -half), half - 1) + half
    }

    /// 0 means no expression at all.
    public var packed: Int {
        var p = 0
        p |= Self.level(vibratoDepth, 7)  // 0-2
        p |= Self.level(vibratoRate, 7) << 3  // 3-5
        p |= Self.signed(scoop, bits: 5) << 6  // 6-10
        p |= Self.level(scoopTime, 3) << 11  // 11-12
        p |= Self.signed(bend, bits: 4) << 13  // 13-16
        p |= (morph.map { $0.index + 1 } ?? 0) << 17  // 17-19
        p |= Self.signed(formantShift, bits: 4) << 20  // 20-23
        p |= Self.level(breath, 7) << 24  // 24-26
        p |= Self.level(grit, 7) << 27  // 27-29
        p |= (snap ? 1 : 0) << 30
        p |= Self.signed(detune / 4, bits: 4) << 31  // 31-34
        p |= echo.index << 35  // 35-36
        p |= Self.level(echoSend, 7) << 37  // 37-39
        p |= filter.index << 40  // 40-41
        p |= (reverse ? 1 : 0) << 42
        p |= min(max(stretch, 0), 3) << 43  // 43-44
        p |= Self.level(swell, 7) << 45  // 45-47
        p |= min(max(Int((bendSpan * 4).rounded()) - 1, 0), 3) << 48  // 48-49
        // Zero is "plain": the biased fields store their midpoint when unset, so flag an all-default note as 0.
        return p == Self.neutral ? 0 : p ^ Self.neutral
    }

    /// The packed value of a note with nothing set; `packed` XORs it away so a plain note is 0.
    private static let neutral: Int = {
        var n = 0
        n |= signed(0, bits: 5) << 6
        n |= signed(0, bits: 4) << 13
        n |= signed(0, bits: 4) << 20
        n |= signed(0, bits: 4) << 31
        n |= level(0.5, 7) << 3  // default vibrato rate
        n |= level(0.3, 3) << 11  // default scoop time
        n |= level(0.5, 7) << 37  // default echo send
        n |= 0 << 48  // default span 0.15 (level 0 after -1 clamp)
        return n
    }()

    public init(packed value: Int) { self = value == 0 ? VocalExpression() : Self.decode(value) }

    private static func decode(_ value: Int) -> VocalExpression {
        var x = VocalExpression()
        let p = value ^ neutral
        func field(_ shift: Int, _ bits: Int) -> Int { (p >> shift) & ((1 << bits) - 1) }
        x.vibratoDepth = Double(field(0, 3)) / 7
        x.vibratoRate = Double(field(3, 3)) / 7
        x.scoop = field(6, 5) - 16
        x.scoopTime = Double(field(11, 2)) / 3
        x.bend = field(13, 4) - 8
        let m = field(17, 3)
        x.morph = m > 0 && m - 1 < VocalVowel.allCases.count ? VocalVowel.allCases[m - 1] : nil
        x.formantShift = field(20, 4) - 8
        x.breath = Double(field(24, 3)) / 7
        x.grit = Double(field(27, 3)) / 7
        x.snap = field(30, 1) == 1
        x.detune = (field(31, 4) - 8) * 4
        x.echo = VocalThrow.allCases[min(field(35, 2), VocalThrow.allCases.count - 1)]
        x.echoSend = Double(field(37, 3)) / 7
        x.filter = VocalFilter.allCases[min(field(40, 2), VocalFilter.allCases.count - 1)]
        x.reverse = field(42, 1) == 1
        x.stretch = field(43, 2)
        x.swell = Double(field(45, 3)) / 7
        x.bendSpan = Double(field(48, 2) + 1) / 4
        return x
    }

    /// Whether the note is plain: the sampler then takes its original, expression-free path.
    public var isPlain: Bool { packed == 0 }
}

extension NoteParams {
    /// A `vocalSample` note with `expression` applied.
    public func expressed(_ expression: VocalExpression) -> NoteParams {
        var p = self
        let packed = expression.packed
        p.expression = packed == 0 ? nil : packed
        return p
    }
}

/// Named treatments of one recorded voice: the same note sung six ways.
extension VocalExpression {
    /// Plain, as sung.
    public static let plain = VocalExpression()
    /// Slow deep vibrato and a scoop into every note: a torch singer.
    public static let torch = VocalExpression(
        vibratoDepth: 0.7, vibratoRate: 0.3, scoop: -2, scoopTime: 0.6, bend: -2, bendSpan: 0.3)
    /// The "power" feel: gritty, breathy, a touch of darker formants.
    public static let power = VocalExpression(
        vibratoDepth: 0.35, vibratoRate: 0.7, scoop: -1, scoopTime: 0.2, formantShift: -2, breath: 0.3, grit: 0.8)
    /// Hard-tuned and a little younger: no drift at all.
    public static let robot = VocalExpression(formantShift: 3, snap: true)
    /// Through a telephone, echoing off the next two beats.
    public static let telephone = VocalExpression(
        vibratoDepth: 0.3, echo: .dottedEighth, echoSend: 0.7, filter: .telephone)
    /// Ah into oh into oo across the note, glassy and deep.
    public static let morphing = VocalExpression(
        vibratoDepth: 0.3, morph: .oo, formantShift: -3, breath: 0.15, swell: 0.4)
    /// Frozen and stretched into a pad.
    public static let frozen = VocalExpression(vibratoDepth: 0.2, formantShift: -1, stretch: 3, swell: 0.8)
}
