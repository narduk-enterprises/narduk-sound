import Foundation
import Testing

@testable import NardukSoundAnalysis

enum Signal {
    static func sine(_ frequency: Double, amplitude: Float, sampleRate: Double = 48_000, count: Int = 2_048) -> [Float]
    {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    /// A square wave of exactly `amplitude` (full-scale peak equals RMS).
    static func square(_ frequency: Double, amplitude: Float, sampleRate: Double = 48_000, count: Int = 2_048)
        -> [Float]
    {
        (0..<count).map { sin(2 * Double.pi * frequency * Double($0) / sampleRate) >= 0 ? amplitude : -amplitude }
    }

    static func dbfs(_ amplitude: Float) -> Float { 20 * log10f(amplitude) }
}

@Suite struct SoundAnalysisTests {
    @Test func a440SineLandsInTheRightBand() {
        let analyzer = SoundAnalyzer(sampleRate: 48_000)
        let samples = Signal.sine(440, amplitude: 0.5)
        var frame = SoundFrame()
        for i in 0..<20 { frame = analyzer.analyze(samples, time: Double(i) / 60) }
        let spectrum = frame.spectrum
        let loudest = spectrum.indices.max { spectrum[$0] < spectrum[$1] } ?? 0
        let center = SpectrumAnalyzer(sampleRate: 48_000).centerFrequency(ofBand: loudest)
        #expect(center > 380 && center < 520, "loudest band centered at \(center) Hz")
        #expect(spectrum[loudest] > 0.85)
        #expect(spectrum[0] < 0.2, "20 Hz band should be quiet, got \(spectrum[0])")
        #expect(spectrum[63] < 0.2, "16 kHz band should be quiet, got \(spectrum[63])")
    }

    @Test func frameShapeMatchesTheContract() {
        let frame = SoundAnalyzer(sampleRate: 44_100).analyze(
            Signal.sine(1_000, amplitude: 0.3, sampleRate: 44_100), time: 1.5)
        #expect(frame.spectrum.count == 64)
        #expect(frame.waveform.count == 512)
        #expect(frame.sequence == 1)
        #expect(frame.time == 1.5)
        #expect(frame.waveform.allSatisfy { abs($0) <= 0.3 + 1e-6 })
    }

    @Test func minusSixDBFSSquareReadsPeakAndRMS() {
        let amplitude = powf(10, -6 / 20)
        let frame = SoundAnalyzer(sampleRate: 48_000).analyze(Signal.square(220, amplitude: amplitude), time: 0)
        #expect(abs(frame.peakDB - -6) < 0.05, "peak \(frame.peakDB)")
        #expect(abs(frame.rmsDB - -6) < 0.05, "rms \(frame.rmsDB)")
    }

    @Test func sineRMSIsThreeDBBelowItsPeak() {
        // 800 Hz at 48 kHz repeats every 60 samples, and the 800-sample loudness window holds whole periods.
        let frame = SoundAnalyzer(sampleRate: 48_000).analyze(Signal.sine(800, amplitude: 0.5), time: 0)
        #expect(abs(frame.peakDB - Signal.dbfs(0.5)) < 0.05, "peak \(frame.peakDB)")
        #expect(abs(frame.rmsDB - (Signal.dbfs(0.5) - 3.0103)) < 0.05, "rms \(frame.rmsDB)")
    }

    @Test func silenceIsSilent() {
        let analyzer = SoundAnalyzer(sampleRate: 48_000)
        let frame = analyzer.analyze([Float](repeating: 0, count: 2_048), time: 0)
        #expect(frame.peakDB == SoundFrame.silenceDB)
        #expect(frame.rmsDB == SoundFrame.silenceDB)
        #expect(frame.spectrum.allSatisfy { $0 == 0 })
        #expect(frame.waveform.allSatisfy { $0 == 0 })
    }

    @Test func shortInputIsFrontPaddedAndSequenceAdvances() {
        let analyzer = SoundAnalyzer(sampleRate: 48_000)
        let first = analyzer.analyze([Float](repeating: 0.25, count: 100), time: 0)
        let second = analyzer.analyze([Float](repeating: 0.25, count: 100), time: 0.016)
        #expect(first.waveform.prefix(412).allSatisfy { $0 == 0 })
        #expect(first.waveform.suffix(100).allSatisfy { $0 == 0.25 })
        #expect(second.sequence == first.sequence + 1)
        analyzer.reset()
        #expect(analyzer.analyze([Float](repeating: 0, count: 10), time: 0).sequence == 1)
    }

    @Test func loudnessIgnoresSamplesOutsideItsWindow() {
        var samples = [Float](repeating: 1, count: 1_000)
        samples.append(contentsOf: [Float](repeating: 0.1, count: 500))
        samples.withUnsafeBufferPointer {
            let (peak, rms) = Loudness.measure($0, window: 500)
            #expect(abs(peak - -20) < 0.01)
            #expect(abs(rms - -20) < 0.01)
        }
    }

    @Test func recentSamplesSourceAnalyzesEveryPoll() {
        let signal = Signal.sine(1_000, amplitude: 0.5, count: 4_096)
        let source = RecentSamplesSource(sampleRate: 48_000) { buffer in
            for i in 0..<buffer.count { buffer[i] = signal[signal.count - buffer.count + i] }
        }
        let first = source.poll(time: 0)
        let second = source.poll(time: 0.016)
        #expect(second.sequence == first.sequence + 1)
        #expect(first.peakDB > -7 && first.peakDB < -5)
    }

    @Test func sampleRingKeepsTheNewestSamples() {
        let ring = SampleRing(capacity: 8)
        #expect(ring.capacity == 8)
        let samples: [Float] = (1...20).map(Float.init)
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 20) }
        var out = [Float](repeating: -1, count: 4)
        #expect(out.withUnsafeMutableBufferPointer { ring.copyRecent(into: $0) })
        #expect(out == [17, 18, 19, 20])
        #expect(ring.totalWritten == 20)
    }

    @Test func sampleRingPadsWithSilenceBeforeTheFirstWrite() {
        let ring = SampleRing(capacity: 16)
        var one: Float = 0.5
        ring.write(&one, count: 1)
        var out = [Float](repeating: -1, count: 4)
        #expect(out.withUnsafeMutableBufferPointer { ring.copyRecent(into: $0) })
        #expect(out == [0, 0, 0, 0.5])
    }

    @Test func sampleRingDownmixesChannels() {
        let ring = SampleRing(capacity: 16)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer {
            left.deallocate()
            right.deallocate()
        }
        for i in 0..<4 {
            left[i] = Float(i)
            right[i] = Float(i) + 2
        }
        let channels = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
        defer { channels.deallocate() }
        channels[0] = left
        channels[1] = right
        ring.write(downmixing: channels, channelCount: 2, frameCount: 4)
        var out = [Float](repeating: -1, count: 4)
        #expect(out.withUnsafeMutableBufferPointer { ring.copyRecent(into: $0) })
        #expect(out == [1, 2, 3, 4])
    }

    @Test func ringSourceReturnsTheSameFrameUntilNewAudioArrives() {
        let source = RingSource(sampleRate: 48_000)
        let silent = source.poll(time: 0)
        #expect(silent.sequence == 0, "nothing written yet, nothing to analyze")
        var samples = Signal.sine(440, amplitude: 0.5, count: 2_048)
        samples.withUnsafeBufferPointer { source.ring.write($0.baseAddress!, count: 2_048) }
        let first = source.poll(time: 0.1)
        let again = source.poll(time: 0.2)
        #expect(first.sequence == 1)
        #expect(again == first)
        samples.withUnsafeMutableBufferPointer { source.ring.write($0.baseAddress!, count: 512) }
        #expect(source.poll(time: 0.3).sequence == 2)
    }
}
