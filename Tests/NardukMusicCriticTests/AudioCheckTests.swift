import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

@testable import NardukMusicCritic

/// The audio half, on offline renders (no audio device, nothing played aloud).
@Suite struct AudioCheckTests {
    static let rate = 48_000.0

    /// Eight bars of kick and snare at 120 BPM, with a 16th-note snare roll in the last bar, and nothing else.
    static func kickAndSnare() -> RenderedAudio {
        let settings = SongSettings(bpm: 120, seed: 1)
        let renderer = OfflineRenderer(settings: settings, sampleRate: rate, playsConductor: false)
        var notes: [ScheduledNote] = []
        for bar in 0..<8 {
            for beat in 0..<4 {
                let step = bar * 16 + beat * 4
                notes.append(ScheduledNote(step: step, instrument: beat % 2 == 0 ? .kick : .snare, velocity: 0.9))
            }
        }
        for step in (7 * 16 + 8)..<(8 * 16) {
            notes.append(ScheduledNote(step: step, instrument: .snare, velocity: 0.7))
        }
        renderer.schedule(notes)
        var left: [Float] = []
        var right: [Float] = []
        while renderer.time < 16.5 {
            let block = renderer.advance()
            left += block.left
            right += block.right
        }
        return RenderedAudio(sampleRate: rate, left: left, right: right)
    }

    @Test func aCleanKickAndSnareHasNoClicksAndAOneSampleStepHasOne() {
        var audio = Self.kickAndSnare()
        #expect(audio.peak > 0.1, "the drums must sound")
        #expect(AudioCheck.clicks(audio).isEmpty, "drum transients and a snare roll are not clicks")
        // A step between two beats (250 ms after a kick at 120 BPM), on both channels.
        let at = Int(2.25 * Self.rate)
        for i in at..<audio.frameCount {
            audio.left[i] += 0.2
            audio.right[i] += 0.2
        }
        let clicks = AudioCheck.clicks(audio)
        #expect(clicks.count == 1)
        #expect(abs((clicks.first ?? 0) - 2.25) < 0.001)
        #expect(AudioCheck.analyze(audio, barSeconds: 2).clicks == 1)
    }

    @Test func clippingSilenceAndLoudnessAreMetered() {
        // One second of a full-scale 100 Hz sine (whole cycles, so it starts and stops at zero), two seconds of silence, one second at half scale.
        let n = Int(Self.rate)
        var samples: [Float] = []
        for i in 0..<n { samples.append(Float(sin(2 * Double.pi * 100 * Double(i) / Self.rate))) }
        samples += [Float](repeating: 0, count: 2 * n)
        for i in 0..<n { samples.append(0.5 * Float(sin(2 * Double.pi * 100 * Double(i) / Self.rate))) }
        let report = AudioCheck.analyze(
            RenderedAudio(sampleRate: Self.rate, left: samples, right: samples), barSeconds: 1.5)
        #expect(report.clippedSamples > 0)
        #expect(report.silenceGaps == 1)
        #expect(abs(report.longestSilence - 2) < 0.02)
        #expect(abs(report.loudestSecondDB - -3.01) < 0.05, "a full-scale sine is -3 dBFS RMS")
        // Mean power over four seconds: (0.5 + 0.125) / 4.
        #expect(abs(report.rmsDB - 10 * log10(0.625 / 4)) < 0.05)
        #expect(abs(report.peakDB) < 0.01)
        #expect(report.clicks == 0)
        #expect(report.drums == nil && report.cost == nil)
    }

    @Test func theCriticsRenderIsOfflineRenderersSampleForSample() {
        let settings = SongSettings(genre: .drumAndBass, seed: 3)
        let signals = SongCritic.energyWave(bars: 8, settings: settings)
        let ticks = 6 * 60
        let critic = CriticRender(settings: settings).render(ticks: ticks, signals: signals)
        let renderer = OfflineRenderer(settings: settings)
        var pending = signals[...]
        var left: [Float] = []
        var right: [Float] = []
        for tick in 0..<ticks {
            var arrived: [MusicSignal] = []
            while let signal = pending.first, signal.time < Double(tick + 1) / OfflineRenderer.tickRate {
                arrived.append(signal)
                pending = pending.dropFirst()
            }
            let block = renderer.advance(signals: arrived)
            left += block.left
            right += block.right
        }
        #expect(critic.fingerprint == RenderedAudio(sampleRate: 48_000, left: left, right: right).fingerprint)
    }

    @Test(arguments: [Genre.techno, .lofi])
    func drumsLandOnTheGridAndAShiftIsMeasured(genre: Genre) {
        // Lo-fi swings its drums a third of a step late; the swing is part of where a hit is due.
        // Two-bar phrases so the drumless intro is over quickly.
        let settings = SongSettings(bpm: genre.defaultBPM, genre: genre, barsPerPhrase: 2, seed: 3)
        let drums: Set<Instrument> = [.kick, .snare]
        let pass = CriticRender(settings: settings, filter: { drums.contains($0.instrument) }, tracked: drums)
        let signals = [MusicSignal(time: 0, level: 0.9)]
        // Lo-fi swings in its drop, three two-bar phrases in.
        let audio = pass.render(ticks: (genre == .lofi ? 24 : 12) * 60, signals: signals)
        let timing = AudioCheck.drumTiming(audio, due: pass.due, latency: pass.limiterLatency)
        #expect(timing.measured >= 8, "\(timing)")
        #expect(timing.worstOffsetMs < 0.5, "\(timing)")
        if genre == .lofi { #expect(timing.maxSwingMs > 10, "lo-fi's hits are swung: \(timing)") }
        // The same hits judged 3 ms early: every one now reads 3 ms off.
        let early = pass.due.map { hit in
            var hit = hit
            hit.sample -= Int(0.003 * 48_000)
            return hit
        }
        let shifted = AudioCheck.drumTiming(audio, due: early, latency: pass.limiterLatency)
        #expect(abs(shifted.worstOffsetMs - 3) < 0.5, "\(shifted)")
        #expect(abs(shifted.meanOffsetMs - 3) < 0.5, "\(shifted)")
    }

    @Test func aRenderReportsItsCostAndDrums() {
        let run = AudioCheck.render(settings: SongSettings(genre: .house, seed: 3), seconds: 4)
        #expect(run.audio.frameCount == 4 * 48_000)
        let cost = run.report.cost
        #expect(cost?.blocks == 240)
        #expect(abs((cost?.budgetMs ?? 0) - 1000.0 / 60) < 1e-9)
        #expect((cost?.worstMs ?? 0) > 0)
        #expect(run.report.drums != nil)
        #expect(run.bars == run.sections.count && run.bars == run.energy.count && run.bars >= 1)
    }
}
