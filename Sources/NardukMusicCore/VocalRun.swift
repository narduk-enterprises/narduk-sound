import Foundation

/// The path a run takes through its scale.
public enum RunShape: String, Sendable, Hashable, Codable, CaseIterable {
    case up, down
    /// Up to the top and back down.
    case updown
    /// Two swells: up and down, then up and down again.
    case wave
}

/// The scale a run climbs (semitones above the root within one octave).
public enum RunScale: String, Sendable, Hashable, Codable, CaseIterable {
    case minorPentatonic, minor, majorPentatonic, blues

    public var intervals: [Int] {
        switch self {
        case .minorPentatonic: [0, 3, 5, 7, 10]
        case .minor: [0, 2, 3, 5, 7, 8, 10]
        case .majorPentatonic: [0, 2, 4, 7, 9]
        case .blues: [0, 3, 5, 6, 7, 10]
        }
    }
}

/// A riff or melisma applied to a held vocal note (narduk-libs#1641): the note holds its root for `hold` of its
/// length, then runs the scale in sixteenths or thirty-seconds over `octaves`, shaped by `shape`, landing on the
/// last degree for the rest of the note. Pure data: `steps` lists the notes, on the half-step grid a `ScheduledNote`
/// has, so a run is the same on every platform.
public struct VocalRun: Sendable, Hashable, Codable {
    /// One note of a run: `half` is the offset from the held note's start in half steps.
    public struct Step: Sendable, Hashable {
        public var half: Int
        public var pitch: Int
        /// Half steps the note lasts.
        public var halves: Int
        /// 0 ... 1 accent, on the beat higher.
        public var accent: Double

        public init(half: Int, pitch: Int, halves: Int, accent: Double) {
            self.half = half
            self.pitch = pitch
            self.halves = halves
            self.accent = accent
        }
    }

    public var shape: RunShape
    public var scale: RunScale
    /// How far the run climbs, in octaves (0.5 ... 3).
    public var octaves: Double
    /// `true` for thirty-seconds (a half step each), `false` for sixteenths (a step each).
    public var fast: Bool
    /// The fraction of the note held on the root before the run starts, 0 ... 0.9.
    public var hold: Double

    public init(
        shape: RunShape = .updown, scale: RunScale = .minorPentatonic, octaves: Double = 1.5, fast: Bool = false,
        hold: Double = 0.3
    ) {
        self.shape = shape
        self.scale = scale
        self.octaves = octaves
        self.fast = fast
        self.hold = hold
    }

    /// The scale degree `k` above `root`, climbing through the octaves.
    func pitch(_ k: Int, root: Int) -> Int {
        let tones = scale.intervals
        return root + 12 * (k / tones.count) + tones[k % tones.count]
    }

    /// The notes of a run over a held note `lengthSteps` long, rooted at `root`.
    public func steps(root: Int, lengthSteps: Int) -> [Step] {
        let total = max(lengthSteps, 1) * 2
        let holdHalves = min(max(Int((Double(total) * min(max(hold, 0), 0.9)).rounded(.down)), 0), total - 2)
        let stride = fast ? 1 : 2
        let count = max((total - holdHalves) / stride, 1)
        let top = max(Int((min(max(octaves, 0.5), 3) * Double(scale.intervals.count)).rounded()), 1)
        var result: [Step] = []
        if holdHalves > 0 { result.append(Step(half: 0, pitch: root, halves: holdHalves, accent: 1)) }
        for i in 0..<count {
            let t = count > 1 ? Double(i) / Double(count - 1) : 0
            let level: Double
            switch shape {
            case .up: level = t
            case .down: level = 1 - t
            case .updown: level = 1 - abs(2 * t - 1)
            case .wave: level = 0.5 - 0.5 * cos(4 * .pi * t)
            }
            let half = holdHalves + i * stride
            let last = i == count - 1
            result.append(
                Step(
                    half: half, pitch: pitch(Int((level * Double(top)).rounded()), root: root),
                    halves: last ? total - half : stride, accent: (half % 4 == 0) ? 1 : 0.8))
        }
        return result
    }
}
