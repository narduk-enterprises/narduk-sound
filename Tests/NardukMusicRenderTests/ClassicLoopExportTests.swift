import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// Writes the gallery's classic demo loop (`DemoPattern`, 140 BPM) to the WAV named by CLASSIC_LOOP_OUT so the
/// gallery's File source can play the same audio its demo plays. Set CLASSIC_LOOP_SECONDS to change the length.
@Suite struct ClassicLoopExportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CLASSIC_LOOP_OUT"] != nil))
    func exportClassicLoop() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["CLASSIC_LOOP_OUT"]!)
        let seconds = Double(env["CLASSIC_LOOP_SECONDS"] ?? "") ?? 96
        let renderer = OfflineRenderer(settings: SongSettings(), playsConductor: false)
        let totalTicks = Int(seconds * OfflineRenderer.tickRate)
        let lastStep = Int(seconds / renderer.settings.secondsPerStep) + 1
        renderer.schedule(DemoPattern.notes(in: 0...lastStep))
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalTicks * renderer.framesPerTick)
        right.reserveCapacity(totalTicks * renderer.framesPerTick)
        for _ in 0..<totalTicks {
            let buffers = renderer.advance()
            left.append(contentsOf: buffers.left)
            right.append(contentsOf: buffers.right)
        }
        let audio = RenderedAudio(sampleRate: renderer.sampleRate, left: left, right: right)
        try AudioFileWriter.writeWAV(audio, to: out)
        #expect(audio.peak > 0.1)
    }
}
