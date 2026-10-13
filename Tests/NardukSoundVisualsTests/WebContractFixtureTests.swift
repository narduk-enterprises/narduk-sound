import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// The contract between this package and its web port (`web/`, `@narduk-enterprises/sound-web`): the numbers the
/// Swift analysis, palette, visual state, flash rules and render budget produce for scripted inputs, written to
/// `web/fixtures/sound-contract.json`. This test fails when the Swift numbers drift from the fixture, and the web
/// tests fail when the TypeScript port drifts from it, so neither side changes alone (docs/web-port.md).
///
/// `NARDUK_WRITE_WEB_FIXTURES=1 swift test --filter WebContractFixtureTests` rewrites the fixture after a deliberate
/// change; then bring the TypeScript port in line until `npm test` in `web/` passes.
@MainActor @Suite struct WebContractFixtureTests {
    static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("web/fixtures/sound-contract.json")

    struct Contract: Codable, Equatable {
        var version = 1
        var analysis: [AnalysisFrame]
        var palettes: Palettes
        var state: [StateCheckpoint]
        var flashLimiter: [Float]
        var lumaWatchdog: [Float]
        var flashColors: [[Float]]
        var budget: [Int]
        var rates: [Int]
        var music: MusicContract
    }

    struct AnalysisFrame: Codable, Equatable {
        var sequence: UInt64
        var spectrum: [Float]
        var chroma: [Float]
        var peakDB: Float
        var rmsDB: Float
        var waveformHead: [Float]
        var waveformTail: [Float]
    }

    struct Palettes: Codable, Equatable {
        var scalar: [[Float]]
        var sections: [[Float]]
        var samples: [[Float]]
        var saturated: [Float]
        var perceptual: [Float]
    }

    struct StateCheckpoint: Codable, Equatable {
        var step: Int
        var spectrum: [Float]
        var peaks: [Float]
        var level: Float
        var energy: Float
        var wild: Float
        var kick: Float
        var peak: Double
        var rms: Double
        var peakHold: Double
        var isSilent: Bool
        var beats: Double
        var travel: Double
        var palette: [Float]
        var historyHead: Int
        var historyCount: Int
    }

    /// `SoundMusicInference` over a scripted drum machine, and the `SoundVisualState` it drives.
    struct MusicContract: Codable, Equatable {
        var frames: Int
        /// Sequences of the frames on which a lane's counter rose: events, compared exactly.
        var kickFrames: [Int]
        var snareFrames: [Int]
        var hatFrames: [Int]
        var impactFrames: [Int]
        /// The sequence on which the tempo locked (0 when it never did).
        var lockSequence: Int
        var sectionChanges: [SectionChange]
        var inference: [InferenceCheckpoint]
        var state: [MusicStateCheckpoint]
    }

    struct SectionChange: Codable, Equatable {
        var sequence: Int
        var section: String
    }

    struct InferenceCheckpoint: Codable, Equatable {
        var sequence: Int
        /// Kick, snare, hat, impact.
        var hits: [Int]
        var step: Int
        var section: String
        var energy: Float
        var isRunning: Bool
        var secondsPerStep: Double
        var wobblePhase: Float
        var wobbleCutoff: Float
        var phraseProgress: Float
        var dropQueued: Bool
        /// 0 until the tempo locks.
        var tempoBPM: Double
    }

    struct MusicStateCheckpoint: Codable, Equatable {
        var sequence: Int
        var section: String
        var isRunning: Bool
        var dropQueued: Bool
        /// Kick, snare, hat, glitch, laser, impact, flash, shake, chroma.
        var envelopes: [Float]
        /// Energy, wild, dropAmount, beatPulse, phraseProgress, wobblePhase, wobbleCutoff, shakeX, shakeY.
        var motion: [Float]
        /// Beats, travel.
        var clock: [Double]
        var palette: [Float]
    }

    // MARK: The scripted inputs (web/test/contract.test.ts generates the same ones)

    /// Sample `index` of analysis frame `frame`: a chord, its echo, silence, then a low tone.
    static func signal(frame: Int, index: Int) -> Float {
        let amplitudes = [0.8, 0.8, 0.5, 0, 0.9, 0.3]
        let g = Double(frame * 800 + index)
        let w = 2 * Double.pi * g / 48_000
        let a = amplitudes[frame]
        if frame >= 4 { return Float(a * (0.9 * sin(60 * w) + 0.1 * sin(1_000 * w))) }
        return Float(a * (0.5 * sin(440 * w) + 0.3 * sin(110 * w) + 0.15 * sin(3_520 * w) + 0.05 * sin(7_040 * w)))
    }

    /// The visual state's frame at update `k`.
    static func stateFrame(_ k: Int) -> SoundFrame {
        let sequence = UInt64(k / 2 + 1)
        if (100..<106).contains(k) { return SoundFrame(sequence: sequence) }
        let level = 0.5 + 0.5 * sin(Double(k) * 0.11)
        var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
        for i in 0..<spectrum.count {
            var value = level * (1 - Double(i) / 64) + 0.2 * sin(Double(k) * 0.37 + Double(i) * 0.5)
            if k % 24 == 0, i < 6 { value += 0.5 }
            spectrum[i] = Float(min(max(value, 0), 1))
        }
        var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
        for j in 0..<waveform.count { waveform[j] = Float(level * sin(Double(j) * 0.07 + Double(k) * 0.9)) }
        let rmsDB = Float(-40 + 30 * level)
        return SoundFrame(
            sequence: sequence, time: Double(k) / 60, spectrum: spectrum, waveform: waveform, peakDB: rmsDB + 6,
            rmsDB: rmsDB)
    }

    static let checkpoints: Set<Int> = [0, 1, 10, 24, 25, 59, 61, 74, 85, 99, 105, 119]

    // MARK: Building the contract

    static func makeContract() -> Contract {
        Contract(
            analysis: analysis(), palettes: palettes(), state: state(), flashLimiter: flashLimiter(),
            lumaWatchdog: lumaWatchdog(), flashColors: flashColors(), budget: budget(),
            rates: [0, -3, 1, 24, 60, 120].map { SoundRenderBudget.rate($0) }, music: music())
    }

    // MARK: Music

    /// The scripted drum machine (web/test/contract.test.ts `drumScript` mirrors it): eight loud seconds at 128 BPM,
    /// a quiet breakdown, three seconds of silence, then six seconds of drums again. 60 frames a second.
    static func drumScript() -> [SoundFrame] {
        var frames = DrumFrames(bpm: 128, rmsDB: -12).frames(seconds: 8)
        frames += DrumFrames(bpm: 128, rmsDB: -34, bed: 0.1, kicks: false, snares: false, hats: false)
            .frames(seconds: 5, from: 481, startTime: 8)
        frames += DrumFrames.silence(seconds: 3, from: 781, startTime: 13)
        frames += DrumFrames(bpm: 128, rmsDB: -18).frames(seconds: 6, from: 961, startTime: 16)
        return frames
    }

    /// The frames of the script drawn in calm mode.
    static let musicCalm = 1000..<1100

    static func music() -> MusicContract {
        let inference = SoundMusicInference()
        let state = SoundVisualState()
        let frames = drumScript()
        var out = MusicContract(
            frames: frames.count, kickFrames: [], snareFrames: [], hatFrames: [], impactFrames: [], lockSequence: 0,
            sectionChanges: [], inference: [], state: [])
        var last = HitCounters()
        var section = SongSection.intro
        for frame in frames {
            let sequence = Int(frame.sequence)
            let music = inference.update(frame)
            if music.hitCounts[.kick] != last[.kick] { out.kickFrames.append(sequence) }
            if music.hitCounts[.snare] != last[.snare] { out.snareFrames.append(sequence) }
            if music.hitCounts[.hat] != last[.hat] { out.hatFrames.append(sequence) }
            if music.hitCounts[.impact] != last[.impact] { out.impactFrames.append(sequence) }
            last = music.hitCounts
            if out.lockSequence == 0, inference.isLocked { out.lockSequence = sequence }
            if music.section != section {
                section = music.section
                out.sectionChanges.append(SectionChange(sequence: sequence, section: section.rawValue))
            }
            let options = SoundVisualOptions(calm: musicCalm.contains(sequence))
            state.update(SoundVisualInput(frame: frame, music: music), now: frame.time + 1, options: options)
            guard sequence % 40 == 20 else { continue }
            out.inference.append(
                InferenceCheckpoint(
                    sequence: sequence,
                    hits: [.kick, .snare, .hat, .impact].map { Int(music.hitCounts[$0]) }, step: music.step,
                    section: music.section.rawValue, energy: music.energy, isRunning: music.isRunning,
                    secondsPerStep: music.secondsPerStep, wobblePhase: music.wobblePhase,
                    wobbleCutoff: music.wobbleCutoff, phraseProgress: music.phraseProgress,
                    dropQueued: music.dropQueued, tempoBPM: inference.tempoBPM ?? 0))
            out.state.append(
                MusicStateCheckpoint(
                    sequence: sequence, section: state.section.rawValue, isRunning: state.isRunning,
                    dropQueued: state.dropQueued,
                    envelopes: [
                        state.kick, state.snare, state.hat, state.glitch, state.laser, state.impact, state.flash,
                        state.shake, state.chroma,
                    ],
                    motion: [
                        state.energy, state.wild, state.dropAmount, state.beatPulse, state.phraseProgress,
                        state.wobblePhase, state.wobbleCutoff, state.shakeOffset.x, state.shakeOffset.y,
                    ],
                    clock: [state.beats, state.travel], palette: flat(state.palette)))
        }
        return out
    }

    static func analysis() -> [AnalysisFrame] {
        let analyzer = SoundAnalyzer(sampleRate: 48_000)
        return (0..<6).map { frame in
            let samples = (0..<SoundAnalyzer.windowSize).map { signal(frame: frame, index: $0) }
            let out = analyzer.analyze(samples, time: Double(frame) / 60)
            return AnalysisFrame(
                sequence: out.sequence, spectrum: out.spectrum, chroma: out.chroma, peakDB: out.peakDB,
                rmsDB: out.rmsDB, waveformHead: Array(out.waveform.prefix(4)),
                waveformTail: Array(out.waveform.suffix(4)))
        }
    }

    static func flat(_ palette: SoundPalette) -> [Float] {
        [palette.c0, palette.c1, palette.c2].flatMap { [$0.x, $0.y, $0.z] }
    }

    static func palettes() -> Palettes {
        let provider = DefaultSoundPaletteProvider()
        let sections: [SongSection] = [.intro, .build, .drop, .breakdown, .drop2]
        let drop = provider.palette(for: .section(.drop))
        let breakdown = provider.palette(for: .section(.breakdown))
        let sampleTimes: [Float] = [-0.3, 0, 0.25, 0.5, 0.9, 1.7]
        return Palettes(
            scalar: [-0.5, 0, 0.2, 0.5, 0.8, 1, 1.5].map { flat(provider.palette(for: .scalar($0))) },
            sections: sections.map { flat(provider.palette(for: .section($0))) },
            samples: sampleTimes.map { t in
                let c = drop.sample(t)
                return [c.x, c.y, c.z]
            },
            saturated: flat(drop.saturated(1.3)),
            perceptual: flat(drop.mixedPerceptually(with: breakdown, 0.5)))
    }

    static func state() -> [StateCheckpoint] {
        let state = SoundVisualState()
        var now = 1.0
        var out: [StateCheckpoint] = []
        for k in 0..<120 {
            let options = SoundVisualOptions(calm: (60..<75).contains(k), drive: (80..<90).contains(k) ? 0.9 : nil)
            state.update(SoundVisualInput(frame: stateFrame(k)), now: now, options: options)
            if checkpoints.contains(k) {
                out.append(
                    StateCheckpoint(
                        step: k, spectrum: Array(state.spectrum), peaks: Array(state.peaks), level: state.level,
                        energy: state.energy, wild: state.wild, kick: state.kick, peak: state.peak, rms: state.rms,
                        peakHold: state.peakHold, isSilent: state.isSilent, beats: state.beats, travel: state.travel,
                        palette: flat(state.palette), historyHead: state.historyHead,
                        historyCount: state.historyCount))
            }
            now += k % 5 == 4 ? 1.0 / 30 : 1.0 / 60
        }
        return out
    }

    static func flashLimiter() -> [Float] {
        var limiter = IntenseFlashLimiter()
        return (0..<180).map { k in
            limiter.limit((k / 4) % 2 == 0 ? 0.9 : 0, now: Double(k) / 60, calm: (120..<150).contains(k))
        }
    }

    static func lumaWatchdog() -> [Float] {
        var watchdog = IntenseLumaWatchdog()
        return (0..<150).map { k in
            let luma: Float = k < 90 ? ((k / 3) % 2 == 0 ? 0.9 : 0.1) : 0.2
            return watchdog.observe(luma: luma, time: Double(k) / 60)
        }
    }

    static func flashColors() -> [[Float]] {
        var limiter = IntenseFlashLimiter()
        return [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0.2, 0.5, 0.9), SIMD3<Float>(0.9, 0.1, 0.4)].map { tint in
            let drive = IntenseDrive(
                flashDemand: 1, glitchDemand: 0.5, tint: tint, calm: false, now: 0, limiter: &limiter)
            return [drive.flashColor.x, drive.flashColor.y, drive.flashColor.z]
        }
    }

    static func budget() -> [Int] {
        var out: [Int] = []
        for visible in [true, false] {
            for thermal in [SoundThermalState.nominal, .fair, .serious, .critical] {
                for lowPower in [false, true] {
                    out.append(
                        SoundRenderBudget.framesPerSecond(isVisible: visible, thermal: thermal, lowPowerMode: lowPower))
                }
            }
        }
        return out
    }

    // MARK: The check

    @Test func theSwiftNumbersMatchTheWebFixture() throws {
        let contract = Self.makeContract()
        if ProcessInfo.processInfo.environment["NARDUK_WRITE_WEB_FIXTURES"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(try Self.forWriting(contract)).write(to: Self.fixtureURL)
        }
        let fixture = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: Self.fixtureURL))
        #expect(fixture.version == contract.version)
        #expect(fixture.budget == contract.budget)
        #expect(fixture.rates == contract.rates)

        // The fixture is written on Linux. On Apple, SpectrumAnalyzer's window is vDSP_HANN_NORM, 0.8165 (1 - cos),
        // against the portable path's 0.5 (1 - cos), so every band reads 4.26 dB hotter there and the spectrum and
        // chroma cannot match the Linux numbers; web/test/contract.test.ts pins that difference instead.
        #expect(fixture.analysis.count == contract.analysis.count)
        for (expected, actual) in zip(fixture.analysis, contract.analysis) {
            #expect(expected.sequence == actual.sequence)
            #if !canImport(Accelerate)
                Self.expectClose(expected.spectrum, actual.spectrum, 2e-3, "spectrum \(actual.sequence)")
                Self.expectClose(expected.chroma, actual.chroma, 2e-3, "chroma \(actual.sequence)")
            #endif
            Self.expectClose([expected.peakDB, expected.rmsDB], [actual.peakDB, actual.rmsDB], 1e-3, "dB")
            Self.expectClose(
                expected.waveformHead + expected.waveformTail, actual.waveformHead + actual.waveformTail,
                1e-6, "waveform")
        }

        let p = fixture.palettes
        let q = contract.palettes
        Self.expectClose(p.scalar.flatMap { $0 }, q.scalar.flatMap { $0 }, 1e-5, "scalar palettes")
        Self.expectClose(p.sections.flatMap { $0 }, q.sections.flatMap { $0 }, 1e-6, "section palettes")
        Self.expectClose(p.samples.flatMap { $0 }, q.samples.flatMap { $0 }, 1e-5, "palette samples")
        Self.expectClose(p.saturated, q.saturated, 1e-5, "saturated")
        Self.expectClose(p.perceptual, q.perceptual, 1e-4, "perceptual")

        #expect(fixture.state.count == contract.state.count)
        for (expected, actual) in zip(fixture.state, contract.state) {
            let label = "state at update \(actual.step)"
            #expect(expected.step == actual.step)
            #expect(expected.isSilent == actual.isSilent, "\(label)")
            #expect(expected.historyHead == actual.historyHead && expected.historyCount == actual.historyCount)
            Self.expectClose(expected.spectrum + expected.peaks, actual.spectrum + actual.peaks, 1e-4, label)
            Self.expectClose(
                [expected.level, expected.energy, expected.wild, expected.kick],
                [actual.level, actual.energy, actual.wild, actual.kick], 1e-4, label)
            Self.expectClose(
                [expected.peak, expected.rms, expected.peakHold, expected.beats, expected.travel].map { Float($0) },
                [actual.peak, actual.rms, actual.peakHold, actual.beats, actual.travel].map { Float($0) }, 1e-4, label)
            Self.expectClose(expected.palette, actual.palette, 1e-4, label)
        }

        Self.checkMusic(fixture.music, contract.music)

        Self.expectClose(fixture.flashLimiter, contract.flashLimiter, 1e-6, "flash limiter")
        Self.expectClose(fixture.lumaWatchdog, contract.lumaWatchdog, 1e-5, "luma watchdog")
        Self.expectClose(fixture.flashColors.flatMap { $0 }, contract.flashColors.flatMap { $0 }, 1e-6, "flash colors")
    }

    /// The contract as it is written to the fixture. The fixture's analysis section is the Linux numbers (the portable
    /// window, see the check below), so a run on Apple keeps the existing one instead of overwriting it with Apple's
    /// hotter bands. Everything else is platform independent.
    static func forWriting(_ contract: Contract) throws -> Contract {
        #if canImport(Accelerate)
            struct Existing: Codable { var analysis: [AnalysisFrame] }
            let existing = try JSONDecoder().decode(Existing.self, from: Data(contentsOf: fixtureURL))
            var out = contract
            out.analysis = existing.analysis
            return out
        #else
            return contract
        #endif
    }

    /// Events (which frame a lane fired on, where the tempo locked, where the section changed) are compared exactly:
    /// they are the contract, and a Float that rounds differently on the two sides only matters if it flips one.
    /// The running values are compared with a tolerance.
    static func checkMusic(_ expected: MusicContract, _ actual: MusicContract) {
        #expect(expected.frames == actual.frames)
        #expect(expected.kickFrames == actual.kickFrames, "kick frames")
        #expect(expected.snareFrames == actual.snareFrames, "snare frames")
        #expect(expected.hatFrames == actual.hatFrames, "hat frames")
        #expect(expected.impactFrames == actual.impactFrames, "impact frames")
        #expect(expected.lockSequence == actual.lockSequence, "tempo lock frame")
        #expect(expected.sectionChanges == actual.sectionChanges, "section changes")

        #expect(expected.inference.count == actual.inference.count)
        for (e, a) in zip(expected.inference, actual.inference) {
            let label = "inference at frame \(a.sequence)"
            #expect(e.sequence == a.sequence)
            #expect(e.hits == a.hits && e.step == a.step && e.section == a.section, "\(label)")
            #expect(e.isRunning == a.isRunning && e.dropQueued == a.dropQueued, "\(label)")
            expectClose(
                [e.energy, e.wobblePhase, e.wobbleCutoff, e.phraseProgress, Float(e.secondsPerStep)],
                [a.energy, a.wobblePhase, a.wobbleCutoff, a.phraseProgress, Float(a.secondsPerStep)], 2e-3, label)
            #expect(abs(e.tempoBPM - a.tempoBPM) < 0.05, "\(label): tempo \(a.tempoBPM) against \(e.tempoBPM)")
        }

        #expect(expected.state.count == actual.state.count)
        for (e, a) in zip(expected.state, actual.state) {
            let label = "music state at frame \(a.sequence)"
            #expect(e.sequence == a.sequence)
            #expect(e.section == a.section && e.isRunning == a.isRunning && e.dropQueued == a.dropQueued, "\(label)")
            expectClose(e.envelopes, a.envelopes, 2e-3, "\(label) envelopes")
            expectClose(e.motion, a.motion, 2e-3, "\(label) motion")
            expectClose(e.clock.map { Float($0) }, a.clock.map { Float($0) }, 2e-3, "\(label) clock")
            expectClose(e.palette, a.palette, 2e-3, "\(label) palette")
        }
    }

    static func expectClose(_ expected: [Float], _ actual: [Float], _ tolerance: Float, _ label: String) {
        #expect(expected.count == actual.count, "\(label): count")
        let worst = zip(expected, actual).map { abs($0 - $1) }.max() ?? 0
        #expect(worst <= tolerance, "\(label): off by \(worst)")
    }
}
