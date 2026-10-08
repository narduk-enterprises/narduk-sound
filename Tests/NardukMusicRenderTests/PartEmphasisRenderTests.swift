import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// Part emphasis at its extremes writes more (or fewer) notes, never louder ones: a 64-bar render stays finite and
/// under the limiter's ceiling.
@Suite struct PartEmphasisRenderTests {
    static let extremes: [(Genre, PartEmphasis)] = [
        (.dubstep, PartEmphasis(drums: 2, bass: 2, keys: 2, guitar: 2, vocals: 2, fx: 2)),
        (.rock, PartEmphasis(drums: 2, bass: 0, keys: 0, guitar: 2, vocals: 2, fx: 0)),
    ]

    @Test(arguments: 0..<2)
    func sixtyFourBarsAtExtremeWeightsStayFiniteAndUnderTheCeiling(index: Int) {
        let (genre, emphasis) = Self.extremes[index]
        let settings = SongSettings(genre: genre, seed: 11, variety: 1)
        let renderer = OfflineRenderer(settings: settings, sampleRate: 24_000)
        renderer.withConductor { $0.setPartEmphasis(emphasis) }
        let seconds = 64 * Double(settings.stepsPerBar) * settings.secondsPerStep
        let ticks = Int((seconds * OfflineRenderer.tickRate).rounded(.up))
        var peak: Float = 0
        var finite = true
        for tick in 0..<ticks {
            // A level that climbs, drops and climbs again, so the set goes through its builds, drops and breakdowns.
            let level = [0.3, 0.95, 0.95, 0.4, 0.95, 0.95][(tick * 6 / max(1, ticks)) % 6]
            let (left, right) = renderer.advance(signals: [MusicSignal(level: level)])
            for sample in left + right {
                finite = finite && sample.isFinite
                peak = max(peak, abs(sample))
            }
        }
        #expect(renderer.withConductor { $0.partEmphasis } == emphasis)
        #expect(finite, "\(genre) wrote a non-finite sample")
        #expect(peak > 0.05 && peak <= DSP.ceiling, "\(genre) peak \(peak)")
    }
}
