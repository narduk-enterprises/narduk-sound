import Foundation

/// Something that can be asked, on the visualizer's clock, what the sound is doing now.
public protocol SoundFrameSource: AnyObject {
    var sampleRate: Double { get }
    /// The latest frame. The sequence number only advances when there is new audio to analyze, so a poll with
    /// nothing new returns the previous frame unchanged.
    func poll(time: Double) -> SoundFrame
}

/// A source over any producer that can copy out its most recent output samples on demand — the music engine's
/// synth core (`copyRecentSamples`), an offline renderer, a file decoder. Every poll analyzes afresh.
public final class RecentSamplesSource: SoundFrameSource {
    public typealias Fill = (UnsafeMutableBufferPointer<Float>) -> Void

    public let sampleRate: Double
    private let fill: Fill
    private let analyzer: SoundAnalyzer
    private var scratch: [Float]

    /// `fill` must write exactly `buffer.count` mono samples, oldest first.
    public init(sampleRate: Double, fill: @escaping Fill) {
        self.sampleRate = sampleRate
        self.fill = fill
        analyzer = SoundAnalyzer(sampleRate: sampleRate)
        scratch = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
    }

    public func poll(time: Double) -> SoundFrame {
        scratch.withUnsafeMutableBufferPointer { fill($0) }
        return scratch.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
    }
}

/// A source fed by a real-time audio thread through a `SampleRing`: push from the tap or render callback, poll from
/// the display clock. Analysis runs on the polling thread, never on the audio thread.
public final class RingSource: SoundFrameSource {
    public let sampleRate: Double
    public let ring: SampleRing
    private let analyzer: SoundAnalyzer
    private var scratch: [Float]
    private var lastWritten = 0
    private var latest = SoundFrame()

    public init(sampleRate: Double, ringSeconds: Double = 0.5) {
        self.sampleRate = sampleRate
        ring = SampleRing(capacity: max(Int(sampleRate * ringSeconds), SoundAnalyzer.windowSize * 2))
        analyzer = SoundAnalyzer(sampleRate: sampleRate)
        scratch = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
    }

    public func poll(time: Double) -> SoundFrame {
        let written = ring.totalWritten
        guard written != lastWritten else { return latest }
        let copied = scratch.withUnsafeMutableBufferPointer { ring.copyRecent(into: $0) }
        guard copied else { return latest }
        lastWritten = written
        latest = scratch.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
        return latest
    }
}
