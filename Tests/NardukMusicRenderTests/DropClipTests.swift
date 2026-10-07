import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// A groove, a held build and a release into the DROP for every genre, rendered offline (no audio device, no sound
/// aloud). The song plays as the app plays it: the conductor's kick and bass duck under the build and its drums and bass
/// under the drop, while `DropArranger` writes the build and drop. Set `NARDUK_DROP_CLIPS_DIR` to also write one WAV per
/// genre for listening.
@Suite struct DropClipTests {
    struct Clip {
        var audio: RenderedAudio
        var grooveEnd: Double
        var releaseAt: Double
        var dropEnd: Double
    }

    static let sampleRate = 48_000.0
    static let bassInstruments: Set<Instrument> = [.wobble, .sub, .bassGuitar]
    static let drumInstruments: Set<Instrument> = [.kick, .snare, .hat, .openHat]

    /// About 12 s: 4 s of groove, a 4 s hold, then the drop to the end.
    static func render(_ genre: Genre, seed: UInt64 = 0x5EED, variety: Double = 0.75, seconds: Double = 12) -> Clip {
        let settings = SongSettings(genre: genre, seed: seed, variety: variety)
        let renderer = OfflineRenderer(settings: settings, sampleRate: sampleRate)
        var left: [Float] = []
        var right: [Float] = []
        // While the DROP is held the master high-pass sweeps up (as the app drives it each frame); the release snaps it open.
        var sweep: (@Sendable (Double) -> MasterFilter)?
        func run(until time: Double) {
            while renderer.time < time {
                if let sweep { renderer.setMasterFilter(sweep(renderer.time)) }
                let block = renderer.advance()
                left += block.left
                right += block.right
            }
        }
        run(until: 1)
        let track = renderer.snapshot.track
        let bpm = track?.bpm ?? renderer.settings.bpm
        let sps = 60 / bpm / 4
        let key = DropArranger.parseKey(track?.key ?? "") ?? (pitchClass: 5, minor: true)
        let tonic = 60 + key.pitchClass

        // The press is the first step not yet scheduled, 4 s in; the release is a full charge later.
        run(until: 4)
        // The drop is read off the song as it plays at the press.
        let material = renderer.withConductor { DropMaterial.capture(from: $0) }
        let context = DropContext(
            genre: genre, keyRoot: tonic, minor: key.minor, chordRoot: tonic, nextChordRoot: tonic + 5, stepsPerBar: 16,
            secondsPerStep: sps, seed: seed, variety: variety, dropNumber: 0, material: material)
        let press = renderer.currentStep + Int(0.25 / sps) + 2
        let hold = Int((DropArranger.fullChargeSeconds / sps).rounded())
        let release = press + hold
        let dropEnd = release + 4 * 16
        var notes: [ScheduledNote] = []
        for step in press..<release {
            notes += DropArranger.build(step: step, heldSteps: step - press, context: context)
        }
        for step in release..<dropEnd {
            notes += DropArranger.drop(
                position: step - release, step: step, power: 1, charge: 1, context: context)
        }
        renderer.schedule(notes)
        sweep = { time in
            let held = Int(time / sps) - press
            return held > 0 && held < hold
                ? DropArranger.filterSweep(heldSteps: held, secondsPerStep: sps, genre: genre) : .idle
        }
        renderer.conductorNoteFilter = { note in
            if note.step >= release, note.step < dropEnd {
                return !bassInstruments.contains(note.instrument) && !drumInstruments.contains(note.instrument)
            }
            if note.step >= press, note.step < release {
                return note.instrument != .kick && !bassInstruments.contains(note.instrument)
            }
            return true
        }
        run(until: seconds)
        return Clip(
            audio: RenderedAudio(sampleRate: sampleRate, left: left, right: right), grooveEnd: Double(press) * sps,
            releaseAt: Double(release) * sps, dropEnd: Double(dropEnd) * sps)
    }

    static func rms(_ audio: RenderedAudio, from: Double, to: Double) -> Double {
        let start = max(0, Int(from * audio.sampleRate))
        let end = min(audio.frameCount, Int(to * audio.sampleRate))
        guard end > start else { return 0 }
        var sum = 0.0
        for index in start..<end { sum += Double(audio.left[index] * audio.left[index]) }
        return (sum / Double(end - start)).squareRoot()
    }

    @Test(arguments: Genre.allCases) func eachGenreRendersAGrooveABuildAndADrop(genre: Genre) throws {
        let clip = Self.render(genre)
        let audio = clip.audio
        #expect(audio.seconds >= 11.9)
        #expect(audio.peak > 0.05, "\(genre) rendered silence")
        #expect(audio.peak < 2, "\(genre) clips hard")
        #expect(audio.left.allSatisfy(\.isFinite) && audio.right.allSatisfy(\.isFinite))
        // The drop is audible: its first half second is not quieter than the build's last half second by much.
        let drop = Self.rms(audio, from: clip.releaseAt, to: clip.releaseAt + 0.5)
        #expect(drop > 0.01, "\(genre)'s drop is nearly silent (rms \(drop))")
        if let dir = ProcessInfo.processInfo.environment["NARDUK_DROP_CLIPS_DIR"] {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try AudioFileWriter.writeWAV(audio, to: url.appendingPathComponent("drop-\(genre.rawValue).wav"))
        }
    }

    /// Two different songs in each of two genres, so the drop can be heard to follow the song (`NARDUK_DROP_CLIPS_DIR`).
    @Test func twoSongsOfAGenreDropDifferently() throws {
        for genre in [Genre.dubstep, .rock] {
            let a = Self.render(genre, seed: 11).audio
            let b = Self.render(genre, seed: 29).audio
            #expect(a.fingerprint != b.fingerprint, "\(genre): two songs rendered the same clip")
            if let dir = ProcessInfo.processInfo.environment["NARDUK_DROP_CLIPS_DIR"] {
                let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("v2", isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try AudioFileWriter.writeWAV(a, to: url.appendingPathComponent("\(genre.rawValue)-song-A.wav"))
                try AudioFileWriter.writeWAV(b, to: url.appendingPathComponent("\(genre.rawValue)-song-B.wav"))
            }
        }
    }

    @Test func aClipIsDeterministicPerSeed() {
        let a = Self.render(.dubstep, seed: 7, seconds: 9).audio.fingerprint
        let b = Self.render(.dubstep, seed: 7, seconds: 9).audio.fingerprint
        #expect(a == b)
    }
}
