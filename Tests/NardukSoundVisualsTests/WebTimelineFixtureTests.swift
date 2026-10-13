import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// The contract between `SoundTimeline` / `SoundTimelinePlayer` and their web port (`web/src/timeline.ts`): a short
/// timeline recorded from a scripted drum machine (frames, not audio, so every platform records the same numbers), its
/// NSTL bytes, and what the Swift player returns for a script of playback times. The web tests decode the same bytes and
/// replay the same times (`web/test/timeline.test.ts`); this test fails when the Swift numbers drift from the fixture.
///
/// `NARDUK_WRITE_WEB_FIXTURES=1 swift test --filter WebTimelineFixtureTests` rewrites `web/fixtures/sound-timeline.json`
/// after a deliberate change; then bring the TypeScript in line until `npm test` in `web/` passes (docs/web-port.md).
@Suite struct WebTimelineFixtureTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("web/fixtures/sound-timeline.json")

    struct Contract: Codable {
        var version = 1
        /// `SoundTimeline.encoded()` of the recording.
        var nstl: Data
        /// The playback times the player is asked for, in order; null is NaN.
        var times: [Double?]
        /// Per call: sequence, step, section code, isRunning, dropQueued, then the hit counter of each header hit lane.
        var counts: [[Int]]
        /// The full frame and context at a subset of the calls.
        var details: [Detail]
    }

    struct Detail: Codable {
        var call: Int
        var time: Double
        var spectrum: [Float]
        var chroma: [Float]
        var peakDB: Float
        var rmsDB: Float
        /// All 512 points, on every few details only.
        var waveform: [Float]?
        var energy: Float
        var wobblePhase: Float
        var wobbleCutoff: Float
        var secondsPerStep: Double
        var phraseProgress: Float
        var buildThreshold: Float
        var dropThreshold: Float
        var stepsPerBar: Int
        var stepsPerPhrase: Int
    }

    // MARK: The scripted recording

    /// 8 s of 128 BPM drums, then 1.5 s of silence, at 60 Hz, each frame with a chirping waveform and a rotating chroma
    /// so the companding, the 32 -> 512 restore and the interpolation all have something to show.
    static func frames() -> [SoundFrame] {
        var out = DrumFrames(bpm: 128).frames(seconds: 8)
        out += DrumFrames.silence(seconds: 1.5, from: UInt64(out.count + 1), startTime: 8)
        for i in out.indices {
            let silent = out[i].rmsDB < -100
            var wave = [Float](repeating: 0, count: SoundFrame.waveformCount)
            if !silent {
                for k in 0..<wave.count {
                    let x = Double(k) / Double(wave.count)
                    let phase = 2 * Double.pi * (3 + 0.01 * Double(i % 90)) * x + 0.3 * Double(i)
                    wave[k] = Float(0.8 * sin(phase) * (0.35 + 0.65 * sin(Double.pi * x)))
                }
            }
            out[i].waveform = wave
            var chroma = [Float](repeating: 0, count: SoundFrame.chromaCount)
            if !silent {
                chroma[(i / 20) % 12] = 0.9
                chroma[(i / 20 + 7) % 12] = 0.4 + 0.3 * Float(sin(Double(i) / 9))
            }
            out[i].chroma = chroma
        }
        return out
    }

    static func record() -> SoundTimeline {
        let recorder = SoundTimelineRecorder(trackID: "web-fixture-1", analysisSampleRate: 48_000)
        for frame in frames() { recorder.record(frame) }
        return recorder.finish()
    }

    /// Playback times that reach every branch of the player: an off-grid forward run (hits accumulate between calls),
    /// the same time twice, a forward jump over the continuity window (no hits), a 60 Hz run, a backward seek, a small
    /// backward step, the end and past it, a negative time and NaN.
    static func times(duration: Double) -> [Double?] {
        var t: [Double?] = []
        for k in 0..<432 { t.append(Double(k) / 144) }  // 0 ... 3 s at 144 Hz
        t.append(t.last!)  // the same time again
        t.append(contentsOf: [3.25, 3.7])  // steps of 0.25 and 0.45 s: inside the window, hits counted
        for k in 0..<60 { t.append(6 + Double(k) / 60) }  // a forward jump to 6 s, then 60 Hz
        for k in 0..<24 { t.append(1.2 + Double(k) / 60) }  // a backward seek
        t.append(1.6 - 0.01)  // a small step back
        t.append(contentsOf: [2.0, 2.0 + 1.0 / 120, 2.0 + 1.0 / 60])  // a jump, then half and one grid step
        t.append(contentsOf: [
            duration - 0.05, duration - 1.0 / 120, duration, duration + 1, duration + 2, duration - 0.5,
        ])
        t.append(contentsOf: [-1, nil, 0.25, 0.25 + 1.0 / 60])
        return t
    }

    static let detailEvery = 9
    static let waveformEvery = 5  // of the details

    static func makeContract() throws -> Contract {
        let nstl = try record().encoded()
        let times = Self.times(duration: try SoundTimeline(decoding: nstl).duration)
        let played = try replay(nstl, times: times)
        return Contract(nstl: nstl, times: times, counts: played.counts, details: played.details)
    }

    static func expectClose(_ a: [Float], _ b: [Float], _ tolerance: Float, _ label: String) {
        #expect(a.count == b.count, "\(label): count")
        var worst: Float = 0
        for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
        #expect(worst <= tolerance, "\(label): off by \(worst)")
    }

    // MARK: The checks

    @Test func theScriptRecordsAUsableTimeline() {
        let timeline = Self.record()
        #expect(timeline.sampleCount == 570)
        #expect(timeline.header.hitLanes.contains(Instrument.kick.index))
        #expect(timeline.header.hitLanes.contains(Instrument.snare.index))
        #expect(timeline.header.tempoBPM != nil, "the tempo locks in 8 s of drums")
        // Some samples run the beat clock, and the silence at the end stops it.
        #expect(timeline.flags.contains { $0 & 8 != 0 })
        #expect(timeline.flags.last! & 8 == 0)
    }

    @Test func theSwiftNumbersMatchTheWebTimelineFixture() throws {
        let contract = try Self.makeContract()
        if ProcessInfo.processInfo.environment["NARDUK_WRITE_WEB_FIXTURES"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(contract).write(to: Self.fixtureURL)
        }
        let fixture = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: Self.fixtureURL))
        #expect(fixture.version == contract.version)

        // The recorder still writes the fixture's timeline. Sample bytes are quantized, so the last bit may differ
        // between platforms' libm; the header, the flags and the hit counts may not.
        let stored = try SoundTimeline(decoding: fixture.nstl)
        let fresh = try SoundTimeline(decoding: contract.nstl)
        #expect(stored.header == fresh.header)
        #expect(stored.flags == fresh.flags)
        #expect(stored.hits == fresh.hits)
        #expect(stored.stepDuration == fresh.stepDuration)
        #expect(zip(stored.spectrum, fresh.spectrum).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(zip(stored.waveform, fresh.waveform).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(zip(stored.position, fresh.position).allSatisfy { abs($0 - $1) <= 1e-3 })

        // The Swift player over the fixture's bytes returns the fixture's numbers.
        #expect(fixture.times.count == contract.times.count)
        let replay = try Self.replay(fixture.nstl, times: fixture.times)
        #expect(replay.counts == fixture.counts)
        #expect(replay.details.count == fixture.details.count)
        for (expected, actual) in zip(fixture.details, replay.details) {
            let label = "call \(expected.call)"
            #expect(expected.call == actual.call)
            Self.expectClose(expected.spectrum, actual.spectrum, 1e-6, "\(label) spectrum")
            Self.expectClose(expected.chroma, actual.chroma, 1e-6, "\(label) chroma")
            Self.expectClose([expected.peakDB, expected.rmsDB], [actual.peakDB, actual.rmsDB], 1e-4, "\(label) dB")
            Self.expectClose(expected.waveform ?? [], actual.waveform ?? [], 1e-6, "\(label) waveform")
            Self.expectClose(
                [expected.energy, expected.wobblePhase, expected.wobbleCutoff, expected.phraseProgress],
                [actual.energy, actual.wobblePhase, actual.wobbleCutoff, actual.phraseProgress], 1e-6, "\(label) music")
            #expect(expected.secondsPerStep == actual.secondsPerStep)
        }
    }

    /// The counts and details the player returns for `times`, from `nstl` alone (what the fixture stores).
    static func replay(_ nstl: Data, times: [Double?]) throws -> (counts: [[Int]], details: [Detail]) {
        let timeline = try SoundTimeline(decoding: nstl)
        var contract = Contract(nstl: nstl, times: times, counts: [], details: [])
        let player = SoundTimelinePlayer(timeline)
        let lanes = timeline.header.hitLanes
        for (call, time) in times.enumerated() {
            let input = player.input(at: time ?? .nan)
            let music = input.music!
            contract.counts.append(
                [
                    Int(input.frame.sequence), music.step, Int(SoundTimeline.sectionCode(music.section)),
                    music.isRunning ? 1 : 0, music.dropQueued ? 1 : 0,
                ] + lanes.map { Int(music.hitCounts.lanes[$0]) })
            if call % detailEvery == 0 || call == times.count - 1 {
                let wantsWave = (contract.details.count % waveformEvery) == 0
                contract.details.append(
                    Detail(
                        call: call, time: input.frame.time, spectrum: input.frame.spectrum, chroma: input.frame.chroma,
                        peakDB: input.frame.peakDB, rmsDB: input.frame.rmsDB,
                        waveform: wantsWave ? input.frame.waveform : nil, energy: music.energy,
                        wobblePhase: music.wobblePhase, wobbleCutoff: music.wobbleCutoff,
                        secondsPerStep: music.secondsPerStep, phraseProgress: music.phraseProgress,
                        buildThreshold: music.buildThreshold, dropThreshold: music.dropThreshold,
                        stepsPerBar: music.stepsPerBar, stepsPerPhrase: music.stepsPerPhrase))
            }
        }
        return (contract.counts, contract.details)
    }
}
