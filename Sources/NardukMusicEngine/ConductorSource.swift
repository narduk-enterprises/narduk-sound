import Foundation
import NardukMusicCore

/// Feeds a `ConductorDriver`'s conductor. The driver owns the value and calls it on its pump thread, under its lock,
/// before every write: keep it quick and never block.
///
/// A scripted curve (`EnergyCurve`) is one; a recipe's script replay is another. Data that arrives on its own clock
/// needs no source: call `ConductorDriver.ingest(_:)` as it comes.
public protocol ConductorSource: Sendable {
    /// Feeds everything due by `time`: seconds of music written through the step about to be written (summed step by
    /// step, so it never runs backwards across a tempo change).
    mutating func feed(_ conductor: inout DropConductor, time: Double)

    /// May add to or change the notes the conductor just wrote (a lead line over the song). Does nothing by default.
    mutating func decorate(_ notes: inout [ScheduledNote], conductor: DropConductor)
}

extension ConductorSource {
    public mutating func decorate(_ notes: inout [ScheduledNote], conductor: DropConductor) {}
}

/// An energy level over song time, sent every `interval` seconds, with a drop queued once per cycle: the song builds,
/// drops and falls away with no data behind it.
public struct EnergyCurve: ConductorSource {
    /// The curve repeats at this length (the drop rule counts cycles of it).
    public var cycleSeconds: Double
    /// Seconds into each cycle from which one drop is queued; nil queues none.
    public var dropAt: Double?
    /// Seconds between signals.
    public var interval: Double
    /// Energy 0 ... 1 at a song time in seconds.
    public var level: @Sendable (Double) -> Double
    private var nextSignal = 0.0
    private var droppedInCycle = -1

    public init(
        cycleSeconds: Double, dropAt: Double? = nil, interval: Double = 0.25,
        level: @escaping @Sendable (Double) -> Double
    ) {
        self.cycleSeconds = max(cycleSeconds, 1)
        self.dropAt = dropAt
        self.interval = max(interval, 0.01)
        self.level = level
    }

    public mutating func feed(_ conductor: inout DropConductor, time: Double) {
        while nextSignal <= time {
            conductor.ingest(MusicSignal(time: nextSignal, level: min(max(level(nextSignal), 0), 1)))
            let cycle = Int(nextSignal / cycleSeconds)
            if let dropAt, nextSignal - Double(cycle) * cycleSeconds >= dropAt, droppedInCycle != cycle {
                droppedInCycle = cycle
                conductor.queueDrop()
            }
            nextSignal += interval
        }
    }

    /// SoundGallery's 32 s loop: a build to 16 s, a hold, a fall, with a drop queued at 15 s.
    public static var loop: EnergyCurve {
        EnergyCurve(cycleSeconds: 32, dropAt: 15) { seconds in
            let t = seconds.truncatingRemainder(dividingBy: 32)
            if t < 16 { return 0.12 + 0.76 * t / 16 }
            if t < 24 { return 0.9 }
            return 0.9 - 0.72 * (t - 24) / 8
        }
    }

    /// Forever Loop's 150 s swell with a slower drift on top, never fully quiet, a drop queued 45 % into each swell.
    public static var swell: EnergyCurve {
        EnergyCurve(cycleSeconds: 150, dropAt: 150 * 0.45) { seconds in
            let phase = seconds / 150 * 2 * .pi
            let swell = 0.5 - 0.5 * cos(phase)
            let drift = 0.08 * sin(phase * 0.37 + 1.3)
            return min(0.95, max(0.1, 0.15 + 0.72 * swell + drift))
        }
    }
}
