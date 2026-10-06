import Foundation
import NardukMusicDSP
import Testing

@testable import NardukMusicCore

/// Measures how varied the conductor's output is inside a track (#45 follow-up: "there isn't enough variety in the
/// output"). The metrics run on throughput only (no discrete traffic events), so they measure the arrangement itself,
/// not the randomness of event placement. Song-level variety (tracks, sessions, genres, traffic) is MusicSongTests.
@Suite struct MusicVarietyTests {
    typealias Base = DropConductorTests

    struct Metrics: CustomStringConvertible {
        var bars = 0
        var uniqueBars = 0
        var uniqueDrumBars = 0
        var uniqueBassBars = 0
        var pitchClasses = 0
        var contours = 0
        var wobbleRates = 0
        var wobbleRateChangesPerMinute = 0.0
        var timbres = 0
        var instruments = 0
        var meanEnergy = 0.0
        var phrases: [SongSection] = []

        var description: String {
            String(
                format: "bars %d | unique bars %d | drum %d | bass %d | pitch classes %d | contours %d | rates %d | "
                    + "rate changes/min %.1f | timbres %d | instruments %d | energy %.2f | ",
                bars, uniqueBars, uniqueDrumBars, uniqueBassBars, pitchClasses, contours, wobbleRates,
                wobbleRateChangesPerMinute, timbres, instruments, meanEnergy)
                + phrases.map(\.rawValue).joined(separator: " ")
        }
    }

    /// Throughput that wanders around a level: `level` 0 ... 1 sets the energy the model settles near.
    static func throughput(level: Double) -> (Int) -> TrafficBatch {
        { step in
            let wave = 1 + 0.35 * sin(Double(step) / 61) + 0.2 * sin(Double(step) / 17)
            // log10(bytes/s) = 3.5 + level * 3.5 at the default 140 BPM step length.
            let bytesPerSecond = pow(10, 3.5 + level * 3.5) * wave
            let perTick = Int(bytesPerSecond * SongSettings().secondsPerStep / 2)
            return Base.traffic(bytesPerTick: perTick)
        }
    }

    static func run(
        _ genre: Genre, level: Double, bars: Int, seed: UInt64 = 0x5EED,
        events: Bool = false
    ) -> (Base.Recording, DropConductor) {
        var settings = SongSettings(genre: genre)
        settings.seed = seed
        var conductor = DropConductor(settings: settings)
        let traffic = throughput(level: level)
        let recording = Base.play(&conductor, steps: bars * 16) { step in
            var batch = traffic(step)
            if events { batch.events = Base.busy(step).events }
            return batch
        }
        return (recording, conductor)
    }

    static func key(_ n: ScheduledNote, _ base: Int) -> String {
        let p = n.params
        return
            "\(n.instrument.rawValue)@\(n.step - base):\(p.pitch ?? -1):\(p.lengthSteps):\(p.wobbleRate?.rawValue ?? "-"):"
            + "\(p.voice ?? -1):\(n.velocity >= 0.5 ? "A" : "g")"
    }

    static func metrics(_ r: Base.Recording, bpm: Double, from: Int, bars: Int) -> Metrics {
        var m = Metrics()
        m.bars = bars
        let drums: Set<Instrument> = [.kick, .snare, .hat, .openHat]
        let bass: Set<Instrument> = [.wobble, .sub]
        var all = Set<String>()
        var drum = Set<String>()
        var line = Set<String>()
        var contours = Set<String>()
        var classes = Set<Int>()
        var rates = Set<WobbleRate>()
        var timbres = Set<String>()
        var instruments = Set<Instrument>()
        var byBar: [Int: [ScheduledNote]] = [:]
        for note in r.notes where note.step >= from * 16 && note.step < (from + bars) * 16 {
            byBar[note.step / 16, default: []].append(note)
        }
        for bar in from..<(from + bars) {
            let notes = (byBar[bar] ?? []).sorted {
                ($0.step, $0.instrument.rawValue) < ($1.step, $1.instrument.rawValue)
            }
            let base = bar * 16
            all.insert(notes.map { key($0, base) }.joined(separator: ","))
            drum.insert(notes.filter { drums.contains($0.instrument) }.map { key($0, base) }.joined(separator: ","))
            line.insert(notes.filter { bass.contains($0.instrument) }.map { key($0, base) }.joined(separator: ","))
            let wobbles = notes.filter { $0.instrument == .wobble }
            let melodic = wobbles.isEmpty ? notes.filter { $0.instrument == .sub } : wobbles
            let pitches = melodic.compactMap(\.params.pitch)
            if pitches.count >= 2 {
                contours.insert(zip(pitches, pitches.dropFirst()).map { "\($1 - $0)" }.joined(separator: ","))
            }
            for note in notes {
                instruments.insert(note.instrument)
                if bass.contains(note.instrument), let pitch = note.params.pitch { classes.insert(pitch % 12) }
                if note.instrument == .wobble {
                    if let rate = note.params.wobbleRate { rates.insert(rate) }
                    timbres.insert(
                        String(
                            format: "%d/%.1f/%.1f", note.params.voice ?? -1, note.params.formant ?? -1,
                            note.params.drive ?? -1))
                }
            }
        }
        let wobbles = r.notes.filter {
            $0.instrument == .wobble && $0.step >= from * 16 && $0.step < (from + bars) * 16
        }
        .sorted { $0.step < $1.step }
        let changes = zip(wobbles, wobbles.dropFirst()).filter { $0.params.wobbleRate != $1.params.wobbleRate }.count
        let minutes = Double(bars * 16) * 60 / bpm / 4 / 60
        m.uniqueBars = all.count
        m.uniqueDrumBars = drum.count
        m.uniqueBassBars = line.count
        m.pitchClasses = classes.count
        m.contours = contours.count
        m.wobbleRates = rates.count
        m.wobbleRateChangesPerMinute = Double(changes) / minutes
        m.timbres = timbres.count
        m.instruments = instruments.count
        let window = r.snapshots[(from * 16)..<min(r.snapshots.count, (from + bars) * 16)]
        m.meanEnergy = window.map(\.energy).reduce(0, +) / Double(max(1, window.count))
        m.phrases = stride(from: 0, to: r.sections.count, by: 128).map { r.sections[$0] }
        return m
    }

    // MARK: Thresholds

    /// Inside a track the music moves where a song moves (chord progressions, phrase-end fills, sections) and repeats
    /// where a song repeats: the bass sound and wobble rate hold through a section (the #54 per-note churn is gone).
    @Test func everyGenreMovesThroughItsChordsAndFills() {
        for genre in Genre.allCases {
            let (r, c) = Self.run(genre, level: 0.8, bars: 16 + 64)
            let m = Self.metrics(r, bpm: c.settings.bpm, from: 16, bars: 64)
            #expect(m.uniqueDrumBars >= 4, "\(genre): \(m)")
            #expect(m.pitchClasses >= 4, "\(genre): \(m)")
            // House and chill carry their hook in the keys; their bass is a groove under it.
            #expect(m.contours >= ([.house, .chill].contains(genre) ? 2 : 3), "\(genre): \(m)")
            #expect(m.wobbleRateChangesPerMinute <= 4, "\(genre): \(m)")
            // Sustained energy still breathes: a breakdown, or the next track's build, comes round before the 10th phrase.
            #expect(m.phrases.dropFirst(3).contains { !$0.isDrop }, "\(genre): \(m)")
        }
    }

    @Test func dubstepWalksItsProgression() {
        let (r, _) = Self.run(.dubstep, level: 0.8, bars: 16 + 64)
        // Each drop phrase's downbeats follow a progression that moves.
        let roots = stride(from: 256, to: 256 + 128, by: 16).compactMap { step in
            r.notes.first { $0.step == step && ($0.instrument == .sub || $0.instrument == .wobble) }?.params.pitch
        }
        #expect(Set(roots.map { $0 % 12 }).count >= 2, "\(roots)")
    }

    @Test func seedsAndTrafficSteerDifferentSongs() {
        var progressions = Set<[Int?]>()
        for seed: UInt64 in [1, 2, 3, 4] {
            let (r, _) = Self.run(.dubstep, level: 0.8, bars: 48, seed: seed)
            progressions.insert(
                stride(from: 256, to: 48 * 16, by: 16).map { step in
                    r.notes.first { $0.step == step && $0.instrument == .sub }?.params.pitch
                })
        }
        #expect(progressions.count >= 3)
        // The same seed with a different top app names (and voices) the record after the app.
        var a = DropConductor(settings: SongSettings())
        var b = DropConductor(settings: SongSettings())
        _ = Base.play(&a, steps: 48 * 16) { _ in Base.traffic(bytesPerTick: 2_500_000, app: "com.spotify.client") }
        _ = Base.play(&b, steps: 48 * 16) { _ in Base.traffic(bytesPerTick: 2_500_000, app: "us.zoom.xos") }
        #expect(a.snapshot.track?.name != b.snapshot.track?.name)
    }

    @Test func longRunsAreDeterministicWithEvents() {
        for genre in Genre.allCases {
            let (a, _) = Self.run(genre, level: 0.8, bars: 96, seed: 77, events: true)
            let (b, _) = Self.run(genre, level: 0.8, bars: 96, seed: 77, events: true)
            #expect(a.notes == b.notes, "\(genre)")
            #expect(a.snapshots == b.snapshots, "\(genre)")
        }
    }

    @Test func breakdownsCarryAVocalLeadOnChordTones() {
        var found = false
        for seed: UInt64 in [1, 2, 3, 4, 5, 6] {
            let (r, _) = Self.run(.dubstep, level: 0.8, bars: 96, seed: seed)
            let lead = r.notes.filter { $0.instrument == .vox && r.sections[$0.step] == .breakdown }
            guard !lead.isEmpty else { continue }
            found = true
            var perBar: [Int: Int] = [:]
            for note in lead { perBar[note.step / 16, default: 0] += 1 }
            #expect(perBar.values.allSatisfy { $0 <= DropConductor.leadNotesPerBar })
            #expect(Set(lead.compactMap(\.params.pitch)).count >= 3)
            #expect(lead.allSatisfy { r.inKey($0) })
        }
        #expect(found)
    }

    @Test func eventsLandOnMusicalSlots() {
        let (r, _) = Self.run(.dubstep, level: 0.8, bars: 48, events: true)
        for note in r.notes {
            let pos = note.step % 16
            switch note.instrument {
            case .laser: #expect(pos % 2 == 0)
            case .scratch: #expect(pos % 4 == 2)
            case .impact: #expect(pos % 4 == 0)
            case .tapeStop: #expect(pos == 4 || pos == 12)
            default: break
            }
        }
        #expect(r.notes.contains { $0.instrument == .laser } && r.notes.contains { $0.instrument == .scratch })
    }

    @Test func variedSongRendersCleanAndLimited() throws {
        for genre in [Genre.dubstep, .house] {
            let stats = try Self.render(genre, level: 0.8, seconds: 12, to: nil)
            #expect(stats.finite)
            #expect(stats.peak <= DSP.ceiling)
            #expect(stats.rmsDB > -18 && stats.rmsDB < -5, "\(genre) RMS \(stats.rmsDB)")
            #expect(stats.dropped == 0)
        }
    }

    // MARK: Report (prints the table)

    @Test func report() {
        var lines: [String] = []
        for genre in Genre.allCases {
            for level in [0.5, 0.7, 0.9] {
                let (r, c) = Self.run(genre, level: level, bars: 16 + 64)
                let m = Self.metrics(r, bpm: c.settings.bpm, from: 16, bars: 64)
                lines.append("\(genre.rawValue) L\(level): \(m)")
            }
        }
        print(lines.joined(separator: "\n"))
    }

    struct RenderStats {
        var peak: Float
        var rmsDB: Float
        var finite: Bool
        var dropped: Int
    }

    /// Plays the conductor with events from 0 and renders `seconds` from 8 bars before the first drop.
    @discardableResult
    static func render(_ genre: Genre, level: Double, seconds: Double, to path: String?) throws -> RenderStats {
        let (r, c) = run(genre, level: level, bars: 16 + 16 + Int(seconds * genre.defaultBPM / 240) + 8, events: true)
        let firstDrop = r.sections.firstIndex { $0.isDrop } ?? 256
        let start = max(0, firstDrop - 8 * 16)
        let bpm = c.settings.bpm
        let sampleRate = 48_000.0
        let core = DropSynthCore(sampleRate: sampleRate, bpm: bpm)
        core.setMasterVolume(1)
        let frames = Int(seconds * sampleRate)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        let secondsPerStep = 60 / bpm / 4
        let lastStep = start + Int(seconds / secondsPerStep) + 1
        let notes = r.notes.filter { $0.step >= start && $0.step <= lastStep }
        var index = 0
        var rendered = 0
        while rendered < frames {
            let through = Int(core.renderedStepPosition + 0.1 / secondsPerStep) + start
            while index < notes.count, notes[index].step <= through {
                var note = notes[index]
                note.step -= start
                core.schedule(note)
                index += 1
            }
            let n = min(512, frames - rendered)
            core.render(frames: n, left: left + rendered, right: right + rendered)
            rendered += n
        }
        var peak: Float = 0
        var sum = 0.0
        var finite = true
        for i in 0..<frames {
            if !left[i].isFinite || !right[i].isFinite { finite = false }
            peak = max(peak, abs(left[i]), abs(right[i]))
            sum += Double(left[i] * left[i] + right[i] * right[i])
        }
        if let path {
            try WAVWriter.write16(
                left: left, right: right, frames: frames, sampleRate: Int(sampleRate), to: URL(fileURLWithPath: path))
        }
        return RenderStats(
            peak: peak, rmsDB: DSP.decibels(Float(sqrt(sum / Double(frames * 2)))), finite: finite,
            dropped: core.droppedEvents)
    }
}
