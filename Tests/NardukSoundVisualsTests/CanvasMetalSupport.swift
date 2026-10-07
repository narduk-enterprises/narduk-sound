#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// Shared scaffolding for the Metal ports of the Canvas visualizers (narduk-libs#1569): a scripted state with a
    /// chosen bass, highs, hits and held notes, rendered at 128 x 72, and the mean luma of a block of its 16 x 9 grid.
    @MainActor enum CanvasMetalSupport {
        static let size = (width: 128, height: 72)
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        /// Renders `kind` after 90 scripted frames. Bands 0 ..< 10 carry `bass`, 36 ... carry `highs`, the rest sit at
        /// 0.03. `kicks`, `snares` and `padHits` land on the last frame, so the envelopes are at their peak; `held` are
        /// MIDI notes held through the last 30 frames (and struck at the start of them).
        static func render(
            _ kind: IntenseKind, bass: Float = 0.3, highs: Float = 0.3, kicks: UInt32 = 0, snares: UInt32 = 0,
            padHits: [Instrument] = [], held: [Int] = [], calm: Bool = false
        ) throws -> [UInt8] {
            let state = SoundVisualState(seed: 9)
            var limiter = IntenseFlashLimiter()
            var now = 2.0
            var spectrum = [Float](repeating: 0.03, count: SoundFrame.spectrumCount)
            for i in 0..<10 { spectrum[i] = bass }
            for i in 36..<SoundFrame.spectrumCount { spectrum[i] = highs }
            let wave = (0..<SoundFrame.waveformCount).map { Float(sin(Double($0) / 9)) * 0.5 }
            var chroma = [Float](repeating: 0.02, count: SoundFrame.chromaCount)
            for note in held { chroma[note % 12] = 0.9 }
            var counts = HitCounters()
            var notes = NoteCounters()
            for frame in 0..<90 {
                if frame == 89 {
                    for _ in 0..<kicks { counts.record(.kick) }
                    for _ in 0..<snares { counts.record(.snare) }
                    for instrument in padHits { counts.record(instrument) }
                }
                var heldSet = NoteSet()
                if frame >= 60 {
                    if frame == 60 { for note in held { notes.record(note) } }
                    heldSet = NoteSet(held)
                }
                let input = SoundVisualInput(
                    frame: SoundFrame(
                        sequence: UInt64(frame + 1), time: Double(frame) / 60, spectrum: spectrum, waveform: wave,
                        peakDB: -8, rmsDB: -14, chroma: chroma),
                    music: MusicContext(
                        hitCounts: counts, step: frame / 4, section: .build, energy: 0.6, isRunning: true,
                        heldNotes: heldSet, noteCounts: notes))
                state.update(input, now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            let renderer = try #require(IntenseRenderer(device: MTLCreateSystemDefaultDevice()))
            return try #require(
                renderer.renderOffscreen(
                    kind, state: state, width: size.width, height: size.height, frames: 1, limiter: &limiter))
        }

        /// Mean luma (0 ... 1) of a block of the 16 x 9 grid: `columns` 0 ... 15 left to right, `rows` 0 ... 8 top down.
        static func luma(_ pixels: [UInt8], columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> Float {
            let grid = WobbleTunnelTests.grid(pixels, width: size.width, height: size.height, columns: 16, rows: 9)
            var sum: Float = 0
            var count: Float = 0
            for row in rows {
                for column in columns {
                    let cell = row * 16 + column
                    sum += (grid[cell * 3] + grid[cell * 3 + 1] + grid[cell * 3 + 2]) / 3
                    count += 1
                }
            }
            return sum / count
        }
    }
#endif
