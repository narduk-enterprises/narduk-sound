import Foundation
import Testing

@testable import NardukSoundAnalysis

@Suite struct ChromaTests {
    /// A chord as the sum of its sines, each at `amplitude`.
    static func chord(_ frequencies: [Double], amplitude: Float = 0.2, count: Int = 2_048) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for f in frequencies {
            let sine = Signal.sine(f, amplitude: amplitude, count: count)
            for i in 0..<count { out[i] += sine[i] }
        }
        return out
    }

    static func settle(_ samples: [Float], rate: Double = 48_000) -> SoundFrame {
        let analyzer = SoundAnalyzer(sampleRate: rate)
        var frame = SoundFrame()
        for i in 0..<30 { frame = analyzer.analyze(samples, time: Double(i) / 60) }
        return frame
    }

    static func strongest(_ chroma: [Float], _ count: Int) -> Set<Int> {
        Set(chroma.indices.sorted { chroma[$0] > chroma[$1] }.prefix(count))
    }

    @Test func anA440SineReadsAsA() {
        let frame = Self.settle(Signal.sine(440, amplitude: 0.5))
        #expect(frame.chroma.count == SoundFrame.chromaCount)
        #expect(Self.strongest(frame.chroma, 1) == [9])
        #expect(frame.chroma[9] > 0.85, "A reads \(frame.chroma[9])")
    }

    @Test func aCMajorTriadReadsAsCEG() {
        // C4, E4, G4 at equal-tempered pitch.
        let frame = Self.settle(Self.chord([261.63, 329.63, 392.0]))
        #expect(Self.strongest(frame.chroma, 3) == [0, 4, 7], "got \(frame.chroma)")
    }

    @Test func theSamePitchClassInAnotherOctaveFoldsToTheSameClass() {
        for frequency in [110.0, 220, 440, 880, 1_760] {
            let frame = Self.settle(Signal.sine(frequency, amplitude: 0.4))
            #expect(Self.strongest(frame.chroma, 1) == [9], "\(frequency) Hz")
        }
    }

    @Test func aSemitoneUpMovesTheClass() {
        let frame = Self.settle(Signal.sine(466.16, amplitude: 0.5))  // A#4
        #expect(Self.strongest(frame.chroma, 1) == [10])
    }

    @Test func chromaWorksAtOtherSampleRates() {
        let frame = Self.settle(Signal.sine(440, amplitude: 0.5, sampleRate: 44_100), rate: 44_100)
        #expect(Self.strongest(frame.chroma, 1) == [9])
    }

    @Test func silenceHasNoChroma() {
        let frame = Self.settle([Float](repeating: 0, count: 2_048))
        #expect(frame.chroma == [Float](repeating: 0, count: SoundFrame.chromaCount))
    }

    @Test func aQuietNoteReadsFainterThanALoudOne() {
        let loud = Self.settle(Signal.sine(440, amplitude: 0.5)).chroma[9]
        let quiet = Self.settle(Signal.sine(440, amplitude: 0.002)).chroma[9]
        #expect(quiet < loud * 0.7, "quiet \(quiet) vs loud \(loud)")
    }

    @Test func theEmptyFrameHasTwelveZeroClasses() {
        #expect(SoundFrame().chroma == [Float](repeating: 0, count: 12))
    }
}
