import Foundation
import Testing

@testable import NardukSoundVisuals

/// The scorecard's maths on synthetic series: runs everywhere, no GPU, no recorded song.
@Suite struct VisualScorecardMathTests {
    @Test func hitResponseSeesAMotionBurstAfterEachHit() {
        var motion = [Double](repeating: 0.01, count: 600)
        let hits = Array(stride(from: 30, to: 540, by: 30))
        for hit in hits {
            motion[hit + 3] = 0.1  // peak 3 frames (50 ms) after the hit
            motion[hit + 4] = 0.05
        }
        let response = VisualScorecard.hitResponse(motion: motion, hits: hits)
        #expect(response.ratio > 2)
        #expect(response.lagMS == 50)
    }

    @Test func hitResponseIsAboutOneForAFlatSeries() {
        let motion = [Double](repeating: 0.02, count: 600)
        let response = VisualScorecard.hitResponse(motion: motion, hits: [60, 120, 180, 240])
        #expect(abs(response.ratio - 1) < 1e-9)
    }

    @Test func tooFewHitsGiveNoRatio() {
        #expect(VisualScorecard.hitResponse(motion: [0.1, 0.2, 0.3, 0.4], hits: [1]).ratio.isNaN)
    }

    @Test func correlationFollowsASmoothedSignalAndIgnoresAFlatOne() {
        let ramp = (0..<300).map(Double.init)
        #expect(abs(VisualScorecard.pearson(ramp, ramp.map { $0 * 2 + 1 }) - 1) < 1e-9)
        #expect(VisualScorecard.pearson(ramp, [Double](repeating: 3, count: 300)).isNaN)
        let smooth = VisualScorecard.smooth([0, 0, 0, 9, 0, 0, 0], width: 3)
        #expect(smooth[3] == 3 && smooth[2] == 3 && smooth[0] == 0)
    }

    @Test func sectionContrastComparesLoudWindowsToQuietOnes() {
        // 10 windows of 2 s; the second half is loud and twice as busy.
        let rms = (0..<1200).map { $0 < 600 ? -40.0 : -10.0 }
        let motion = (0..<1200).map { $0 < 600 ? 0.01 : 0.02 }
        let luma = (0..<1200).map { _ in 0.3 }
        let contrast = VisualScorecard.sectionContrast(rmsDB: rms, motion: motion, luma: luma)
        #expect(abs(contrast.motion - 2) < 1e-9)
        #expect(abs(contrast.luma - 1) < 1e-9)
    }

    @Test func scoreReportsRangeAndSteadiness() {
        let frames = (0..<300).map { i in
            VisualScorecard.Frame(
                luma: Float(i % 10) / 10, spread: 0.2, motion: i < 60 ? 0 : 0.01, hue: 0, saturation: 0)
        }
        let inputs = (0..<300).map { i in
            VisualScorecard.Input(rmsDB: -20, kick: i % 30 == 5, snare: false)
        }
        let m = VisualScorecard.score(frames: frames, inputs: inputs)
        #expect(m.luma.p10 < m.luma.p50 && m.luma.p50 < m.luma.p90)
        #expect(abs(m.frozenShare - 0.2) < 1e-9)
        #expect(m.kickHits == 10 && m.snareHits == 0 && m.snareRatio.isNaN)
    }

    @Test func windowChoiceFindsTheQuietToLoudTransition() {
        // 100 s at 60 Hz: silent for 40 s, then loud. The best 20 s window straddles 40 s.
        let rms = (0..<6000).map { $0 < 2400 ? -80.0 : -12.0 }
        let start = VisualScorecard.chooseWindow(rmsDB: rms, gridRate: 60, seconds: 20)
        #expect(start > 20 && start < 40)
        // A silent lead-in and a fade-out at the edges are not the quiet part: the window stays inside the margins.
        let edges: [Double] = (0..<6000).map { i -> Double in
            if i < 300 || i > 5700 { return -90 }
            return -20 + Double(i % 600) / 60
        }
        let inside = VisualScorecard.chooseWindow(rmsDB: edges, gridRate: 60, seconds: 20)
        #expect(inside >= 10 && inside <= 70)
    }

    @Test func hueOfPrimaries() {
        #expect(VisualScorecard.hueSaturation(r: 1, g: 0, b: 0).hue == 0)
        #expect(abs(VisualScorecard.hueSaturation(r: 0, g: 1, b: 0).hue - 1.0 / 3) < 1e-6)
        #expect(VisualScorecard.hueSaturation(r: 0.5, g: 0.5, b: 0.5).saturation == 0)
    }
}
