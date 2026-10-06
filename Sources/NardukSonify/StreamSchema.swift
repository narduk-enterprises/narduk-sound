import Foundation
import NardukMusicCore

/// The columns of a stream, fixed up front. A sample is then just its values in this order, so ingesting one needs no
/// dictionary and no sorting: it can run at motion or audio rates.
public struct StreamSchema: Sendable, Hashable {
    public let names: [String]

    public init(_ names: [String]) { self.names = names }

    public var count: Int { names.count }

    public func index(of name: String) -> Int? { names.firstIndex(of: name) }
}

/// What kind of thing a stream did. Open: the sonifier raises the standard kinds below, and an app can add its own
/// (`StreamEventKind("brake")`) and map them to its own events.
public struct StreamEventKind: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let peak: StreamEventKind = "peak"
    public static let trough: StreamEventKind = "trough"
    public static let anomaly: StreamEventKind = "anomaly"
    public static let jump: StreamEventKind = "jump"
    public static let crossing: StreamEventKind = "crossing"
    public static let rise: StreamEventKind = "rise"
    public static let voicePeak: StreamEventKind = "voicePeak"
    public static let voiceTrough: StreamEventKind = "voiceTrough"
}

/// One thing the stream did, for an event feed and for visuals.
public struct StreamEvent: Sendable, Hashable, Identifiable {
    public var id: String { "\(index)|\(kind.rawValue)|\(column)" }
    /// The index of the sample (in arrival order) that confirmed the event.
    public var index: Int
    public var kind: StreamEventKind
    public var column: String
    public var detail: String

    public init(index: Int, kind: StreamEventKind, column: String, detail: String) {
        self.index = index
        self.kind = kind
        self.column = column
        self.detail = detail
    }
}

/// Decides which column leads (drives the energy) and which follow as voices: higher rank leads, the first column wins
/// a tie. The library knows nothing about what a column means; the app that does supplies a ranker, for example one
/// that puts a headline measurement above bookkeeping.
public struct StreamColumnRanker: Sendable {
    public var rank: @Sendable (String) -> Int

    public init(_ rank: @escaping @Sendable (String) -> Int) { self.rank = rank }

    /// Every column ranks the same, so the first column leads.
    public static let uniform = StreamColumnRanker { _ in 0 }
}

enum StreamCueOrder {
    /// How loud a cue is when a frame carries more than the conductor takes: higher survives.
    static func priority(_ gesture: MusicCue.Gesture) -> Int {
        switch gesture {
        case .impact: 10
        case .tapeStop: 9
        case .swell: 8
        case .zap: 7
        case .voice: 6
        case .stutter: 5
        case .scratch: 4
        case .spark: 3
        case .ghost: 2
        case .sparkle: 1
        case .tick: 0
        }
    }

    static func format(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if magnitude >= 10_000 { return String(format: "%.1fk", value / 1_000) }
        if magnitude >= 100 || value == value.rounded() { return String(format: "%.0f", value) }
        if magnitude >= 1 { return String(format: "%.2f", value) }
        return String(format: "%.3g", value)
    }
}
