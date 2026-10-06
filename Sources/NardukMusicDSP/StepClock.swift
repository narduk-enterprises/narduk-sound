import Foundation
import NardukMusicCore

/// Maps 16th-note steps to sample positions with exact integer arithmetic, so the
/// grid never drifts: step n starts at `anchorSample + floor((n - anchorStep) * sampleRate * 15 / bpm)`.
/// BPM is held in thousandths. A tempo change is scheduled for the next bar boundary and
/// takes over from the exact sample where that bar starts.
public struct StepClock: Sendable, Hashable {
    public let sampleRate: Int
    public private(set) var anchorStep: Int
    public private(set) var anchorSample: Int
    public private(set) var bpmMilli: Int
    /// A scheduled tempo change (Int.max when none).
    public private(set) var pendingStep: Int = .max
    public private(set) var pendingSample: Int = .max
    public private(set) var pendingBpmMilli: Int = 0

    public init(sampleRate: Int, bpm: Double, startSample: Int = 0) {
        self.sampleRate = max(sampleRate, 1)
        self.anchorStep = 0
        self.anchorSample = startSample
        self.bpmMilli = StepClock.milliBPM(bpm)
    }

    public static func milliBPM(_ bpm: Double) -> Int {
        let clamped = bpm.isFinite ? min(max(bpm, 20), 400) : 140
        return Int((clamped * 1000).rounded())
    }

    /// The tempo the clock will run at once any pending change lands.
    public var targetBpmMilli: Int { pendingStep == .max ? bpmMilli : pendingBpmMilli }

    public var bpm: Double { Double(bpmMilli) / 1000 }

    public var samplesPerStep: Double { Double(sampleRate) * 15_000 / Double(bpmMilli) }

    @inline(__always) static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Samples from a segment start to `steps` steps later at `bpmMilli`.
    @inline(__always) public static func offset(steps: Int, sampleRate: Int, bpmMilli: Int) -> Int {
        floorDiv(steps * sampleRate * 15_000, bpmMilli)
    }

    /// The first sample of `step`.
    @inline(__always) public func sample(forStep step: Int) -> Int {
        if step >= pendingStep {
            return pendingSample
                + StepClock.offset(steps: step - pendingStep, sampleRate: sampleRate, bpmMilli: pendingBpmMilli)
        }
        return anchorSample + StepClock.offset(steps: step - anchorStep, sampleRate: sampleRate, bpmMilli: bpmMilli)
    }

    /// The step playing at `sample` (the largest n with sample(forStep: n) <= sample).
    public func step(atSample sample: Int) -> Int {
        let k = sampleRate * 15_000
        if sample >= pendingSample {
            return pendingStep + StepClock.floorDiv((sample - pendingSample + 1) * pendingBpmMilli - 1, k)
        }
        return anchorStep + StepClock.floorDiv((sample - anchorSample + 1) * bpmMilli - 1, k)
    }

    /// Fractional step position at `sample` (for display and look-ahead).
    public func stepPosition(atSample sample: Int) -> Double {
        let k = Double(sampleRate) * 15_000
        if sample >= pendingSample {
            return Double(pendingStep) + Double(sample - pendingSample) * Double(pendingBpmMilli) / k
        }
        return Double(anchorStep) + Double(sample - anchorSample) * Double(bpmMilli) / k
    }

    /// Requests `bpm`; it applies from the next bar boundary after `currentSample`.
    public mutating func requestTempo(_ bpm: Double, currentSample: Int, stepsPerBar: Int = 16) {
        requestTempo(milli: StepClock.milliBPM(bpm), currentSample: currentSample, stepsPerBar: stepsPerBar)
    }

    public mutating func requestTempo(milli: Int, currentSample: Int, stepsPerBar: Int = 16) {
        advance(to: currentSample)
        guard milli != targetBpmMilli else { return }
        if pendingStep != .max {
            // A change is already queued for a future bar: retarget it at the same boundary.
            pendingBpmMilli = milli
            return
        }
        let bar = max(stepsPerBar, 1)
        let boundary = (StepClock.floorDiv(step(atSample: currentSample), bar) + 1) * bar
        let boundarySample = sample(forStep: boundary)
        pendingStep = boundary
        pendingSample = boundarySample
        pendingBpmMilli = milli
    }

    /// Commits a pending tempo change once the clock has reached it.
    public mutating func advance(to sample: Int) {
        guard pendingStep != .max, sample >= pendingSample else { return }
        anchorStep = pendingStep
        anchorSample = pendingSample
        bpmMilli = pendingBpmMilli
        pendingStep = .max
        pendingSample = .max
        pendingBpmMilli = 0
    }
}
