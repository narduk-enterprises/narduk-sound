import Foundation
import NardukMusicCore

/// What one stream sample plays.
public struct StreamFrame: Sendable {
    public var index: Int
    public var time: Double
    public var level: Double
    public var melody: Double
    public var motion: Double
    public var events: [StreamEvent]
    public var cues: [MusicCue]
    public var character: MusicCharacter?
    public var drop: Bool
}

/// A sonifier for data that never ends: each sample is analysed as it arrives (`OnlineSeries`), its events are
/// rate-limited as they happen (a token bucket instead of a whole-file top-N), and the drop comes on a new high of the
/// recent window instead of the file's peak.
///
/// The columns are fixed by a `StreamSchema` and a sample is its values in that order, so `ingest` allocates nothing
/// while no event fires (events and their cue labels are the only strings it builds).
public struct StreamSonifier: Sendable {
    public struct Config: Sendable, Hashable {
        public var window = 2048
        /// Seconds of history the pitch range is drawn from.
        public var span = 60.0
        public var smoothing = 0.2
        public var memory = 20.0
        /// Events heard per second on average (about one a beat at 140 BPM), with a burst of `burst`.
        public var eventsPerSecond = 2.0
        public var burst = 4.0
        public var dropCooldown = 60.0
        public init() {}
    }

    /// How many columns beyond the leader play as voices.
    public static let voiceLimit = 4

    public let schema: StreamSchema
    public let config: Config
    public private(set) var energyColumn: String
    public private(set) var voiceColumns: [String] = []
    public private(set) var series: [OnlineSeries]
    public private(set) var index = 0
    private var energyIndex = 0
    /// Per column: the voice slot it plays in, or nil; and the stereo position of that slot.
    private var voiceSlot: [Int?]
    private var voicePan: [Double]
    private var tokens = 2.0
    private var lastEventTime = -Double.infinity
    private var lastTime: Double?
    private var lastDrop = -Double.infinity
    private var heat = 0.0
    private var started = false

    /// - Parameters:
    ///   - energy: the leading column; nil picks the best-ranked one (the first on a tie).
    ///   - ranker: how to rank columns when `energy` is nil; the default ranks them all alike.
    public init(
        schema: StreamSchema, energy: String? = nil, ranker: StreamColumnRanker = .uniform, config: Config = Config()
    ) {
        precondition(schema.count > 0, "a stream needs at least one column")
        self.schema = schema
        self.config = config
        series = schema.names.map {
            OnlineSeries(
                name: $0, window: config.window, span: config.span, smoothing: config.smoothing, memory: config.memory)
        }
        voiceSlot = [Int?](repeating: nil, count: schema.count)
        voicePan = [Double](repeating: 0, count: schema.count)
        let lead =
            energy.flatMap(schema.index(of:))
            ?? schema.names.indices.reduce(0) { best, next in
                ranker.rank(schema.names[next]) > ranker.rank(schema.names[best]) ? next : best
            }
        energyColumn = schema.names[lead]
        setEnergy(column: lead)
    }

    public var energy: OnlineSeries { series[energyIndex] }

    /// Makes `name` the leading column; the previous leader joins the voices first. No-op for an unknown name.
    public mutating func setEnergy(column name: String) {
        guard let column = schema.index(of: name), column != energyIndex else { return }
        let previous = energyIndex
        var order = voiceColumns.compactMap(schema.index(of:)).filter { $0 != column }
        order.insert(previous, at: 0)
        setEnergy(column: column, voices: order)
    }

    private mutating func setEnergy(column: Int) {
        let others = schema.names.indices.filter { $0 != column }
        setEnergy(column: column, voices: others)
    }

    private mutating func setEnergy(column: Int, voices: [Int]) {
        energyIndex = column
        energyColumn = schema.names[column]
        let slots = Array(voices.prefix(Self.voiceLimit))
        voiceColumns = slots.map { schema.names[$0] }
        for i in schema.names.indices {
            voiceSlot[i] = slots.firstIndex(of: i)
            voicePan[i] =
                voiceSlot[i].map {
                    slots.count == 1 ? 0.5 : -0.8 + 1.6 * Double($0) / Double(slots.count - 1)
                } ?? 0
        }
    }

    /// Analyses one sample: `values` holds one number per schema column, in schema order. A value that is not finite
    /// means the column had nothing this time and is skipped.
    public mutating func ingest(time: Double, values: UnsafeBufferPointer<Double>) -> StreamFrame {
        precondition(values.count == schema.count, "a sample carries one value per schema column")
        let dt = lastTime.map { Swift.max(0, time - $0) } ?? 0
        lastTime = time
        tokens = Swift.min(config.burst, tokens + dt * config.eventsPerSecond)
        heat *= exp(-dt / 10)
        var candidates: [Candidate] = []
        for column in 0..<values.count {
            let change = series[column].add(values[column], time: time)
            if change.isQuiet { continue }
            collect(change, column: column, into: &candidates)
        }
        if !started {
            started = true
            let energy = series[energyIndex]
            candidates.append(
                Candidate(
                    cues: [.sparkle("\(energyColumn) starts at \(StreamCueOrder.format(energy.value))")],
                    event: StreamEvent(index: index, kind: .crossing, column: energyColumn, detail: "start"),
                    weight: 100))
        }
        // Rate limit as it happens: strong events spend a token, weak ones only when the bucket is nearly full, and
        // never two within a 16th. Online there is no "best N of the file", so the bucket is the budget.
        var events: [StreamEvent] = []
        var cues: [MusicCue] = []
        if !candidates.isEmpty {
            for candidate in candidates.sorted(by: { $0.weight > $1.weight }) {
                let needed = candidate.weight >= 2 ? 1.0 : config.burst - 0.5
                guard candidate.weight >= 50 || (tokens >= needed && time - lastEventTime >= 0.12) else { continue }
                if candidate.weight < 50 { tokens -= 1 }
                lastEventTime = time
                events.append(candidate.event)
                cues += candidate.cues
            }
        }
        let lead = series[energyIndex]
        var drop = false
        if lead.count > 256, lead.level >= 0.98, time - lastDrop >= config.dropCooldown {
            drop = true
            lastDrop = time
        }
        let frame = StreamFrame(
            index: index, time: time, level: lead.level, melody: lead.melody, motion: lead.motion, events: events,
            cues: cues, character: character(lead), drop: drop)
        index += 1
        return frame
    }

    public mutating func ingest(time: Double, values: [Double]) -> StreamFrame {
        values.withUnsafeBufferPointer { ingest(time: time, values: $0) }
    }

    private struct Candidate {
        var cues: [MusicCue]
        var event: StreamEvent
        var weight: Double
    }

    private mutating func collect(_ change: OnlineSeries.Change, column: Int, into candidates: inout [Candidate]) {
        let name = schema.names[column]
        let online = series[column]
        let voice = voiceSlot[column]
        let isEnergy = column == energyIndex
        func add(_ cues: [MusicCue], _ kind: StreamEventKind, _ detail: String, _ weight: Double) {
            candidates.append(
                Candidate(
                    cues: cues, event: StreamEvent(index: index, kind: kind, column: name, detail: detail),
                    weight: weight))
        }
        if let z = change.anomalyZ, isEnergy || voice != nil {
            heat += 1
            let text = "anomaly \(name) z=\(String(format: "%+.1f", z))"
            add([.impact(text), .stutter(text)], .anomaly, text, (isEnergy ? 3 : 2) + abs(z) / 2)
        }
        if isEnergy {
            if let peak = change.peak {
                let text = "peak \(name) \(StreamCueOrder.format(online.smooth))"
                add([.zap(text, height: online.level)], .peak, text, 2 + abs(peak.z))
            }
            if let trough = change.trough {
                let text = "trough \(name) \(StreamCueOrder.format(online.smooth))"
                add([.ghost(text)], .trough, text, 1.6 + abs(trough.z))
            }
            if let up = change.jumped {
                let text = "\(name) jumps \(up ? "up" : "down")"
                add([.scratch(text)], .jump, text, 2.5)
            }
            if change.rising { add([.swell("\(name) climbing")], .rise, "starts climbing", 2.2) }
            if change.crossed { add([.tick("\(name) crosses mean")], .crossing, "crosses its mean", 0.6) }
        } else if voice != nil {
            let pan = voicePan[column]
            if let peak = change.peak {
                add(
                    [.spark("\(name) peak", key: "\(name)+", pan: pan)], .voicePeak, "\(name) peak", 1 + abs(peak.z) / 2
                )
            }
            if let trough = change.trough {
                add(
                    [.spark("\(name) trough", key: "\(name)-", pan: pan)], .voiceTrough, "\(name) trough",
                    0.9 + abs(trough.z) / 2)
            }
        }
    }

    /// The conductor's character from the recent shape: anomalies → chaos, barely moving → idle, a strong climb → surge.
    private func character(_ energy: OnlineSeries) -> MusicCharacter? {
        guard energy.count > 64 else { return nil }
        if heat >= 2 { return .chaos }
        if energy.localZ > 1.2, energy.motion > 0.1 { return .surge }
        if energy.motion < 0.03 { return .idle }
        return .busy
    }

    /// The conductor's signal for the frames since the last tick. Builds a `MusicSignal`, so it allocates: call it
    /// once per tick, not once per sample.
    public func signal(_ frames: [StreamFrame], time: Double) -> (signal: MusicSignal, queueDrop: Bool) {
        guard let last = frames.last else { return (MusicSignal(time: time), false) }
        let lead = series[energyIndex]
        var cues = frames.flatMap(\.cues)
        let faults = Double(cues.filter { $0.gesture == .impact }.count)
        if cues.count > 10 {
            cues = Array(
                cues.sorted { StreamCueOrder.priority($0.gesture) > StreamCueOrder.priority($1.gesture) }.prefix(10))
        }
        var sources: [String: Double] = [energyColumn: last.motion * 1_000]
        for name in voiceColumns { sources[name] = (schema.index(of: name).map { series[$0].motion } ?? 0) * 1_000 }
        let bytes = last.level * 2_000_000 / 60
        let signal = MusicSignal(
            time: time,
            level: last.level,
            levelLabel: "\(energyColumn) \(StreamCueOrder.format(lead.value))",
            flow: MusicFlow(
                inbound: bytes, outbound: bytes * 0.2, starts: Double(cues.count) - faults, faults: faults,
                sources: sources),
            cues: cues,
            pan: 0,
            character: last.character)
        return (signal, frames.contains(where: \.drop))
    }
}

extension OnlineSeries.Change {
    /// Nothing happened: the common case, which must cost nothing.
    var isQuiet: Bool {
        peak == nil && trough == nil && !crossed && jumped == nil && !rising && anomalyZ == nil
    }
}
