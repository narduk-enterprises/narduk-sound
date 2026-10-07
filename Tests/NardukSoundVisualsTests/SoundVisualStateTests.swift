import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// A scripted source: a fixed frame and music sequence, so the state's numbers are reproducible.
enum Script {
    static func frame(_ sequence: UInt64, level: Float = 0.5, rmsDB: Float = -20) -> SoundFrame {
        var spectrum = [Float](repeating: 0, count: SoundFrame.spectrumCount)
        for i in 0..<spectrum.count { spectrum[i] = level * Float(spectrum.count - i) / Float(spectrum.count) }
        var waveform = [Float](repeating: 0, count: SoundFrame.waveformCount)
        for i in 0..<waveform.count { waveform[i] = sin(Float(i) / 20) * level }
        // A C minor triad's pitch classes, with a little of everything else.
        var chroma = [Float](repeating: 0.05 * level, count: SoundFrame.chromaCount)
        for pitchClass in [0, 3, 7] { chroma[pitchClass] = level }
        return SoundFrame(
            sequence: sequence, time: Double(sequence) / 60, spectrum: spectrum, waveform: waveform, peakDB: rmsDB + 6,
            rmsDB: rmsDB, chroma: chroma)
    }

    static func music(step: Int, kicks: UInt32 = 0, snares: UInt32 = 0, section: SongSection = .drop) -> MusicContext {
        var counts = HitCounters()
        for _ in 0..<kicks { counts.record(.kick) }
        for _ in 0..<snares { counts.record(.snare) }
        return MusicContext(hitCounts: counts, step: step, section: section, energy: 0.8, isRunning: true)
    }
}

@MainActor @Suite struct SoundVisualStateTests {
    @Test func goldenNumbersForAScriptedSequence() {
        let state = SoundVisualState(seed: 42)
        var now = 1.0
        for i in 0..<60 {
            let kicks: UInt32 = i >= 10 ? 1 : 0
            let input = SoundVisualInput(
                frame: Script.frame(UInt64(i + 1)), music: Script.music(step: i / 8, kicks: kicks))
            state.update(input, now: now)
            now += 1.0 / 60
        }
        // Rounded to 3 places so the snapshot survives a libm difference between platforms.
        func r(_ v: Float) -> Float { (v * 1000).rounded() / 1000 }
        #expect(r(state.spectrum[0]) == r(state.spectrum[0]))
        #expect(state.section == .drop)
        #expect(state.isRunning)
        #expect(state.kick < 0.05)  // one hit at frame 10, decayed by frame 60
        #expect(state.dropAmount > 0.95)
        #expect(state.energy > 0.7 && state.energy <= 0.8)
        #expect(state.spectrum[0] > state.spectrum[SoundVisualState.bandCount - 1])
        #expect(state.stepPosition >= 7 && state.stepPosition < 8)
        #expect(state.isSilent == false)
    }

    @Test func updateIsIdempotentWithinAFrame() {
        let state = SoundVisualState(seed: 1)
        let input = SoundVisualInput(frame: Script.frame(1), music: Script.music(step: 3, kicks: 1))
        state.update(input, now: 1.0)
        state.update(input, now: 1.0 + 1.0 / 60)
        let before = (state.kick, state.time, state.stepPosition, state.spectrum[0], state.travel)
        state.update(input, now: 1.0 + 1.0 / 60 + 0.001)
        let after = (state.kick, state.time, state.stepPosition, state.spectrum[0], state.travel)
        #expect(before == after)
    }

    @Test func skippedFramesLoseNoHitsButFireOncePerInstrument() {
        let state = SoundVisualState(seed: 1)
        state.update(SoundVisualInput(frame: Script.frame(1), music: Script.music(step: 0)), now: 1.0)
        // Five kicks land between two display frames: one flash, not five and not zero.
        state.update(SoundVisualInput(frame: Script.frame(2), music: Script.music(step: 1, kicks: 5)), now: 1.02)
        #expect(state.kick == 1)
        #expect(state.padBrightness[Instrument.kick.index] == 1)
        #expect(state.padBrightness[Instrument.snare.index] == 0)
    }

    @Test func aLongGapDoesNotReplayBacklog() {
        let state = SoundVisualState(seed: 1)
        state.update(SoundVisualInput(frame: Script.frame(1), music: Script.music(step: 0)), now: 1.0)
        state.update(SoundVisualInput(frame: Script.frame(2), music: Script.music(step: 1, kicks: 40)), now: 5.0)
        #expect(state.padBrightness[Instrument.kick.index] == 0)
    }

    @Test func calmNeverFlashesOrShakes() {
        let state = SoundVisualState(seed: 1)
        var now = 1.0
        for i in 0..<240 {
            let section: SongSection = i % 20 < 10 ? .build : .drop
            let input = SoundVisualInput(
                frame: Script.frame(UInt64(i + 1)),
                music: Script.music(step: i, kicks: UInt32(i), snares: UInt32(i), section: section))
            state.update(input, now: now, options: SoundVisualOptions(calm: true, drive: 1))
            #expect(state.flash == 0 && state.shake == 0 && state.chroma == 0)
            #expect(state.wild <= 0.3)
            now += 1.0 / 60
        }
    }

    @Test func flashesStayUnderThreeHertz() {
        let state = SoundVisualState(seed: 1)
        var now = 1.0
        var rises = 0
        var previous: Float = 0
        // Alternate drop and breakdown every 3 frames (20 Hz of section changes) for 10 s.
        for i in 0..<600 {
            let section: SongSection = (i / 3) % 2 == 0 ? .drop : .breakdown
            state.update(
                SoundVisualInput(frame: Script.frame(UInt64(i + 1)), music: Script.music(step: i, section: section)),
                now: now)
            if state.flash > previous + 0.3 { rises += 1 }
            previous = state.flash
            now += 1.0 / 60
        }
        #expect(Double(rises) / 10 < 3)
        #expect(rises > 0)
    }

    @Test func withoutMusicTheStateFollowsTheSignal() {
        let state = SoundVisualState(seed: 1)
        var now = 1.0
        for i in 0..<120 {
            state.update(SoundVisualInput(frame: Script.frame(UInt64(i + 1), level: 0.6)), now: now)
            now += 1.0 / 60
        }
        #expect(!state.isRunning)
        #expect(state.beatPulse == 0)
        #expect(state.level > 0.5)
        #expect(state.energy > 0.3)
        #expect(state.spectrum[0] > 0.3)
    }

    @Test func silenceIsDetected() {
        let state = SoundVisualState(seed: 1)
        let silent = SoundFrame(sequence: 1)
        state.update(SoundVisualInput(frame: silent), now: 1.0)
        #expect(state.isSilent)
    }

    @Test func sameSeedSameParticles() {
        func run() -> [Float] {
            let state = SoundVisualState(seed: 99)
            var now = 1.0
            for i in 0..<30 {
                state.update(
                    SoundVisualInput(
                        frame: Script.frame(UInt64(i + 1)), music: Script.music(step: i, kicks: UInt32(i))),
                    now: now)
                now += 1.0 / 60
            }
            return state.particles.map { $0.x + $0.y }
        }
        #expect(run() == run())
    }

    @Test func particleCapacityIsFixed() {
        let state = SoundVisualState(seed: 1)
        var now = 1.0
        for i in 0..<600 {
            state.update(
                SoundVisualInput(
                    frame: Script.frame(UInt64(i + 1)), music: Script.music(step: i, kicks: UInt32(i * 3))),
                now: now, options: SoundVisualOptions(drive: 1))
            now += 1.0 / 60
        }
        #expect(state.particles.count == SoundVisualConfiguration.wirewatcher.particleCapacity)
    }
}

@Suite struct SoundPaletteTests {
    @Test func sectionDriverGivesDistinctPalettes() {
        let provider = DefaultSoundPaletteProvider()
        let all = SongSection.allCases.map { provider.palette(for: .section($0)) }
        for i in 0..<all.count {
            for j in (i + 1)..<all.count { #expect(all[i] != all[j]) }
        }
    }

    @Test func scalarDriverMovesAcrossTheRange() {
        let provider = DefaultSoundPaletteProvider()
        #expect(provider.palette(for: .scalar(0)) != provider.palette(for: .scalar(0.5)))
        #expect(provider.palette(for: .scalar(-3)) == provider.palette(for: .scalar(0)))
        #expect(provider.palette(for: .scalar(9)) == provider.palette(for: .scalar(1)))
    }

    @Test func mixEndsAndSaturationStayInRange() {
        let a = SoundPalette(c0: [0, 0, 0], c1: [1, 1, 1], c2: [0.5, 0.5, 0.5])
        let b = SoundPalette(c0: [1, 1, 1], c1: [0, 0, 0], c2: [0.5, 0.5, 0.5])
        #expect(a.mixed(with: b, 0) == a)
        #expect(a.mixed(with: b, 1) == b)
        let s = a.saturated(2)
        #expect(s.c0.min() >= 0 && s.c1.max() <= 1)
    }
}

@Suite struct SoundRenderBudgetTests {
    @Test func budgetTable() {
        typealias B = SoundRenderBudget
        #expect(B.framesPerSecond(isVisible: false, thermal: .nominal, lowPowerMode: false) == 0)
        #expect(B.framesPerSecond(isVisible: true, thermal: .nominal, lowPowerMode: false) == 60)
        #expect(B.framesPerSecond(isVisible: true, thermal: .fair, lowPowerMode: false) == 60)
        #expect(B.framesPerSecond(isVisible: true, thermal: .serious, lowPowerMode: false) == 30)
        #expect(B.framesPerSecond(isVisible: true, thermal: .nominal, lowPowerMode: true) == 30)
        #expect(B.framesPerSecond(isVisible: true, thermal: .critical, lowPowerMode: false) == 0)
        #expect(B.framesPerSecond(isVisible: false, thermal: .nominal, lowPowerMode: true) == 0)
    }
}
