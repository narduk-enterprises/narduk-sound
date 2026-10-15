import Foundation
import NardukMusicCore
import NardukSoundAnalysis
import Testing

@testable import NardukSoundVisuals

/// A drum machine rendered straight into `SoundFrame`s: bands rise on each hit and relax the way `SpectrumAnalyzer`
/// smooths them (attack 0.65, release 0.12 per frame), 60 frames a second, so the inference hears what it would hear
/// from the analyzer without any audio.
struct DrumFrames {
    var bpm = 128.0
    var frameRate = 60.0
    /// Loudness while the drums play, and the spectrum's resting level.
    var rmsDB: Float = -18
    var bed: Float = 0.25
    var kicks = true
    var snares = true
    var hats = true

    func frames(seconds: Double, from sequence: UInt64 = 1, startTime: Double = 0) -> [SoundFrame] {
        var bands = [Float](repeating: bed, count: SoundFrame.spectrumCount)
        var out: [SoundFrame] = []
        let count = Int(seconds * frameRate)
        let beat = 60 / bpm
        for i in 0..<count {
            let time = Double(i) / frameRate
            let position = time / beat
            let beatIndex = Int(position.rounded(.down))
            let sinceBeat = (position - Double(beatIndex)) * beat
            let sinceHalf = (position * 2 - (position * 2).rounded(.down)) * beat / 2
            let kick = kicks && sinceBeat < 0.04
            let snare = snares && beatIndex % 2 == 1 && sinceBeat < 0.04
            let hat = hats && sinceHalf < 0.02
            for b in 0..<bands.count {
                var target = bed
                if kick, b >= 4, b < 22 { target = 0.9 }
                if snare, b >= 22, b < 44 { target = max(target, 0.8) }
                if hat, b >= 46 { target = max(target, 0.7) }
                bands[b] += (target - bands[b]) * (target > bands[b] ? 0.65 : 0.12)
            }
            out.append(
                SoundFrame(
                    sequence: sequence + UInt64(i), time: startTime + time, spectrum: bands, peakDB: rmsDB + 6,
                    rmsDB: rmsDB))
        }
        return out
    }

    static func silence(seconds: Double, from sequence: UInt64 = 1, startTime: Double = 0) -> [SoundFrame] {
        (0..<Int(seconds * 60)).map {
            SoundFrame(sequence: sequence + UInt64($0), time: startTime + Double($0) / 60)
        }
    }
}

@Suite struct SoundMusicInferenceTests {
    @Test func silenceHearsNothing() {
        let inference = SoundMusicInference()
        var music = MusicContext()
        for frame in DrumFrames.silence(seconds: 5) { music = inference.update(frame) }
        #expect(music.hitCounts == HitCounters())
        #expect(!music.isRunning)
        #expect(inference.tempoBPM == nil)
        #expect(music.energy == 0)
        #expect(music.section == .intro)
    }

    @Test func aFourOnTheFloorLocksTheTempoAndCountsTheDrums() {
        let inference = SoundMusicInference()
        let frames = DrumFrames(bpm: 128).frames(seconds: 12)
        var music = MusicContext()
        var stepAt10 = 0
        for frame in frames {
            music = inference.update(frame)
            if frame.sequence == 601 { stepAt10 = music.step }
        }
        let bpm = try? #require(inference.tempoBPM)
        #expect(bpm.map { abs($0 - 128) < 2 } == true, "tempo \(String(describing: bpm))")
        #expect(music.isRunning)
        // 12 s at 128 BPM is 25.6 beats: a kick on each, a snare on every other one, a hat on every half.
        let kicks = Int(music.hitCounts[.kick])
        let snares = Int(music.hitCounts[.snare])
        let hats = Int(music.hitCounts[.hat])
        #expect(kicks >= 23 && kicks <= 27, "kicks \(kicks)")
        #expect(snares >= 11 && snares <= 14, "snares \(snares)")
        #expect(hats >= 46 && hats <= 54, "hats \(hats)")
        // The clock runs at 4 steps a beat: the last two seconds are 4.27 beats, 17 steps.
        let steps = music.step - stepAt10
        #expect(steps >= 15 && steps <= 19, "steps in the last 2 s: \(steps)")
        #expect(abs(music.secondsPerStep - 60 / 128 / 4) < 0.002)
        // The beat lands on the kicks: the frame after a kick is near a step boundary that is a multiple of 4.
        #expect(music.stepsPerBar == 16)
    }

    @Test func aHalfTimeFeelIsNotHeardAsDoubleTime() {
        let inference = SoundMusicInference()
        var music = MusicContext()
        for frame in DrumFrames(bpm: 90).frames(seconds: 12) { music = inference.update(frame) }
        let bpm = inference.tempoBPM ?? 0
        #expect(abs(bpm - 90) < 2 || abs(bpm - 180) < 4, "tempo \(bpm)")
        #expect(music.isRunning)
    }

    @Test func loudDrumsAreADropAndTheQuietAfterThemABreakdown() {
        let inference = SoundMusicInference()
        var sections: [SongSection] = []
        let loud = DrumFrames(bpm: 128, rmsDB: -12).frames(seconds: 8)
        for frame in loud {
            sections.append(inference.update(frame).section)
        }
        #expect(sections.contains(.drop), "never reached a drop: \(Set(sections))")
        #expect(inference.latest.hitCounts[.impact] >= 1)
        let quiet = DrumFrames(bpm: 128, rmsDB: -34, bed: 0.1, kicks: false, snares: false, hats: false)
            .frames(seconds: 6, from: 1 + UInt64(loud.count), startTime: 8)
        for frame in quiet { sections.append(inference.update(frame).section) }
        #expect(sections.last == .breakdown, "ended in \(String(describing: sections.last))")
        #expect(inference.latest.energy < 0.4)
    }

    @Test func theContextCarriesTheHeardLoudnessAsEnergy() {
        let inference = SoundMusicInference()
        var loudest: Float = 0
        for frame in DrumFrames(bpm: 128, rmsDB: -12).frames(seconds: 8) {
            let music = inference.update(frame)
            #expect(music.energy == inference.loudness * SoundMusicInference.contextEnergyScale)
            loudest = max(loudest, music.energy)
        }
        #expect(loudest > 0.25, "loud drums only reached energy \(loudest)")
        let quiet = DrumFrames(bpm: 128, rmsDB: -34, bed: 0.1, kicks: false, snares: false, hats: false)
            .frames(seconds: 6, from: 481, startTime: 8)
        var music = MusicContext()
        for frame in quiet { music = inference.update(frame) }
        #expect(music.energy < loudest / 2, "the quiet after them still read \(music.energy)")
    }

    @Test func aFrameAlreadyHeardChangesNothing() {
        let inference = SoundMusicInference()
        let frames = DrumFrames().frames(seconds: 3)
        for frame in frames { inference.update(frame) }
        let before = inference.latest
        let again = inference.update(frames[frames.count - 1])
        #expect(again == before)
    }

    @Test func resetForgetsTheLock() {
        let inference = SoundMusicInference()
        for frame in DrumFrames().frames(seconds: 12) { inference.update(frame) }
        #expect(inference.isLocked)
        inference.reset()
        #expect(!inference.isLocked)
        #expect(inference.latest == MusicContext())
    }
}

#if canImport(Darwin)
    /// `update` runs on the display clock next to `SoundVisualState.update`; it must not allocate either. Counts
    /// allocations the way `SoundVisualStateAllocationTests` does; only an optimized build means anything.
    @Suite(.serialized) struct SoundMusicInferenceAllocationTests {
        static let optimized = SoundVisualStateAllocationTests.optimized

        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func hearingADrumMachineNeverAllocates() throws {
            let inference = SoundMusicInference()
            // Frames are built before arming: the caller owns them, the inference only reads.
            let frames = DrumFrames(bpm: 124).frames(seconds: 10)
            for frame in frames[0..<60] { inference.update(frame) }
            let count = try SoundVisualStateAllocationTests.countAllocations {
                for frame in frames[60...] { inference.update(frame) }
            }
            #expect(
                count == 0,
                "update allocated \(count) times, first at:\n\(SoundVisualStateAllocationTests.firstAllocationStack)")
            #expect(inference.isLocked)
        }
    }
#endif
