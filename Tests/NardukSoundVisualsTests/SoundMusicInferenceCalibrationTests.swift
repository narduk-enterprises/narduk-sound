#if canImport(AVFoundation)
    import Foundation
    import NardukMusicCore
    import NardukMusicDSP
    import NardukMusicRender
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// The engine knows the truth about its own songs: every hit, the step clock, the section. Rendering one offline and
    /// hearing it back through `SoundAnalyzer` and `SoundMusicInference` scores the inference against that truth, the
    /// way the live gallery would hear the same song through a loopback device.
    struct InferenceScore {
        var genre: Genre
        var trueBPM: Double
        var heardBPM: Double?
        /// Seconds until the clock locked; nil if it never did.
        var lockTime: Double?
        var kickRecall: Double
        var kickPrecision: Double
        var snareRecall: Double
        var snarePrecision: Double
        /// Fraction of ticks after the lock on which "is a drop" agreed with the conductor.
        /// Fraction of locked ticks on which the tempo agreed with the song's (or its double or half).
        var tempoShare: Double
        var dropAgreement: Double
        var trueDropShare: Double
        var heardDropShare: Double
        /// Mean absolute beat phase error of inferred kicks against the conductor's step clock, in beats (0 ... 0.5).
        var beatError: Double

        /// True when the tempo matches the song's, its double or its half, within `tolerance`.
        var tempoAgrees: Bool {
            guard let heardBPM else { return false }
            return [1.0, 2.0, 0.5].contains { abs(heardBPM / (trueBPM * $0) - 1) < 0.03 }
        }

        var line: String {
            String(
                format:
                    "%@ true=%.0f heard=%@ lock=%@ kick r=%.2f p=%.2f snare r=%.2f p=%.2f tempo ok=%.2f drop agree=%.2f (true %.2f heard %.2f) beat err=%.2f",
                "\(genre)".padding(toLength: 12, withPad: " ", startingAt: 0), trueBPM,
                heardBPM.map { String(format: "%.1f", $0) } ?? "nil",
                lockTime.map { String(format: "%.1fs", $0) } ?? "never",
                kickRecall, kickPrecision, snareRecall, snarePrecision, tempoShare, dropAgreement, trueDropShare,
                heardDropShare, beatError)
        }

        /// Renders `seconds` of a `genre` song (the conductor driven to a drop by a level signal at `driveAt` seconds) and
        /// scores the inference on it.
        static func measure(
            genre: Genre, seconds: Double = 48, driveAt: Double = 4, seed: UInt64 = 0x5EED, classicLoop: Bool = false
        ) -> InferenceScore {
            var settings = SongSettings()
            if !classicLoop {
                settings.genre = genre
                settings.bpm = genre.defaultBPM
                settings.seed = seed
            }
            let renderer = OfflineRenderer(settings: settings, playsConductor: !classicLoop)
            if classicLoop {
                renderer.schedule(DemoPattern.notes(in: 0...(Int(seconds / settings.secondsPerStep) + 1)))
            }
            func truthSection() -> SongSection {
                classicLoop ? DemoPattern.section(atStep: renderer.currentStep) : renderer.snapshot.section
            }
            let analyzer = SoundAnalyzer(sampleRate: renderer.sampleRate)
            let inference = SoundMusicInference()
            var window = [Float](repeating: 0, count: SoundAnalyzer.windowSize)
            let ticks = Int(seconds * OfflineRenderer.tickRate)
            var trueKicks: [Int] = []
            var trueSnares: [Int] = []
            var heardKicks: [Int] = []
            var heardSnares: [Int] = []
            var kickSteps: [Double] = []
            var last = HitCounters()
            var lockTick: Int?
            var agree = 0
            var tempoOK = 0
            var scored = 0
            var trueDrops = 0
            var heardDrops = 0
            var stepAtTick: [Double] = []
            var previous = SoundFrame()
            var previous2 = SoundFrame()
            struct SectionStats {
                var ticks = 0
                var rms = 0.0
                var low = 0.0
                var mid = 0.0
                var high = 0.0
                var kicks = 0
                var snares = 0
                var hats = 0
                var energy = 0.0
                var heardBuild = 0
                var heardDrop = 0
            }
            var stats: [SongSection: SectionStats] = [:]
            for tick in 0..<ticks {
                let time = Double(tick + 1) / OfflineRenderer.tickRate
                let drive = !classicLoop && tick == Int(driveAt * OfflineRenderer.tickRate)
                let signals = drive ? [MusicSignal(time: time, level: 0.95)] : []
                _ = renderer.advance(signals: signals)
                let hits = renderer.takeHits()
                if hits.contains(.kick) { trueKicks.append(tick) }
                if hits.contains(.snare) { trueSnares.append(tick) }
                window.withUnsafeMutableBufferPointer { renderer.copyRecentSamples(into: $0) }
                let frame = window.withUnsafeBufferPointer { analyzer.analyze($0, time: time) }
                let music = inference.update(frame)
                if ProcessInfo.processInfo.environment["INFER_SECTIONS"] != nil {
                    var st = stats[truthSection(), default: SectionStats()]
                    st.ticks += 1
                    st.rms += Double(frame.rmsDB)
                    st.low += Double(frame.spectrum[0..<16].reduce(0, +) / 16)
                    st.mid += Double(frame.spectrum[16..<40].reduce(0, +) / 24)
                    st.high += Double(frame.spectrum[40..<64].reduce(0, +) / 24)
                    st.energy += Double(music.energy)
                    if music.section == .build { st.heardBuild += 1 }
                    if music.section == .drop || music.section == .drop2 { st.heardDrop += 1 }
                    if hits.contains(.kick) { st.kicks += 1 }
                    if hits.contains(.snare) { st.snares += 1 }
                    if hits.contains(.hat) || hits.contains(.openHat) { st.hats += 1 }
                    stats[truthSection()] = st
                }
                if ProcessInfo.processInfo.environment["INFER_TIMELINE"] != nil, tick % 30 == 0 {
                    print(
                        String(
                            format: "tl %@ t=%5.1f truth=%@ heard=%@ energy=%.2f level=%.2f peak=%.2f rms=%.1f bpm=%@",
                            "\(genre)", time, "\(truthSection())".padding(toLength: 9, withPad: " ", startingAt: 0),
                            "\(music.section)".padding(toLength: 9, withPad: " ", startingAt: 0), music.energy,
                            inference.level, inference.levelPeak, frame.rmsDB,
                            inference.tempoBPM.map { String(format: "%.1f", $0) } ?? "-"))
                }
                let delta = music.hitCounts.delta(since: last)
                last = music.hitCounts
                // The conductor's step as a continuous beat position at this tick.
                let truthStep = Double(classicLoop ? renderer.currentStep : renderer.snapshot.step)
                stepAtTick.append(truthStep)
                if delta[.kick] > 0 {
                    heardKicks.append(tick)
                    kickSteps.append(truthStep)
                    if ProcessInfo.processInfo.environment["INFER_KICKS"] != nil {
                        let near = trueKicks.last.map { tick - $0 <= 4 } ?? false
                        func rise(_ r: Range<Int>) -> Float {
                            var t: Float = 0
                            for i in r { t += max(0, frame.spectrum[i] - previous.spectrum[i]) }
                            return t / Float(r.count)
                        }
                        func rise2(_ r: Range<Int>) -> Float {
                            var t: Float = 0
                            for i in r { t += max(0, previous.spectrum[i] - previous2.spectrum[i]) }
                            return t / Float(r.count)
                        }
                        var bins = ""
                        for b in stride(from: 0, to: 64, by: 8) { bins += String(format: " %.3f", rise(b..<(b + 8))) }
                        print(
                            String(
                                format: "kick %@ t=%5.2f snare=%d bins=%@ peak=%.1f rms=%.1f", near ? "TRUE " : "FALSE",
                                time, delta[.snare] > 0 ? 1 : 0, bins, frame.peakDB, frame.rmsDB))
                    }
                }
                previous2 = previous
                previous = frame
                if delta[.snare] > 0 { heardSnares.append(tick) }
                if lockTick == nil, inference.isLocked { lockTick = tick }
                if lockTick != nil {
                    scored += 1
                    if let heard = inference.tempoBPM,
                        [1.0, 2.0, 0.5].contains(where: { abs(heard / (settings.bpm * $0) - 1) < 0.03 })
                    {
                        tempoOK += 1
                    }
                    let truthSection = truthSection()
                    let truthDrop = truthSection == .drop || truthSection == .drop2
                    let heardDrop = music.section == .drop || music.section == .drop2
                    if truthDrop { trueDrops += 1 }
                    if heardDrop { heardDrops += 1 }
                    if truthDrop == heardDrop { agree += 1 }
                }
            }
            for (section, st) in stats.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let n = Double(st.ticks)
                print(
                    String(
                        format:
                            "  %@ %@ %4.1fs rms=%.1f low=%.2f mid=%.2f high=%.2f kick/s=%.1f snare/s=%.1f hat/s=%.1f heardEnergy=%.2f heard build=%.2f drop=%.2f",
                        "\(genre)", "\(section)".padding(toLength: 9, withPad: " ", startingAt: 0), n / 60, st.rms / n,
                        st.low / n, st.mid / n, st.high / n, Double(st.kicks) / n * 60, Double(st.snares) / n * 60,
                        Double(st.hats) / n * 60, st.energy / n, Double(st.heardBuild) / n, Double(st.heardDrop) / n))
            }
            func match(_ truth: [Int], _ heard: [Int], within: Int = 4) -> (recall: Double, precision: Double) {
                guard !truth.isEmpty, !heard.isEmpty else { return (0, 0) }
                var hit = 0
                for t in truth where heard.contains(where: { abs($0 - t) <= within }) { hit += 1 }
                var right = 0
                for h in heard where truth.contains(where: { abs($0 - h) <= within }) { right += 1 }
                return (Double(hit) / Double(truth.count), Double(right) / Double(heard.count))
            }
            let kick = match(trueKicks, heardKicks)
            let snare = match(trueSnares, heardSnares)
            // Beat error: how far each heard kick sits from the nearest conductor beat (a multiple of 4 steps). The
            // conductor's step only moves 60 times a second too, so a kick on the step is error 0.
            var beatErrors: [Double] = []
            for step in kickSteps {
                let beats = step / 4
                let error = abs(beats - beats.rounded())
                beatErrors.append(error)
            }
            let beatError = beatErrors.isEmpty ? 0.5 : beatErrors.reduce(0, +) / Double(beatErrors.count)
            return InferenceScore(
                genre: genre, trueBPM: settings.bpm, heardBPM: inference.tempoBPM,
                lockTime: lockTick.map { Double($0) / OfflineRenderer.tickRate },
                kickRecall: kick.recall, kickPrecision: kick.precision, snareRecall: snare.recall,
                snarePrecision: snare.precision, tempoShare: scored > 0 ? Double(tempoOK) / Double(scored) : 0,
                dropAgreement: scored > 0 ? Double(agree) / Double(scored) : 0,
                trueDropShare: scored > 0 ? Double(trueDrops) / Double(scored) : 0,
                heardDropShare: scored > 0 ? Double(heardDrops) / Double(scored) : 0, beatError: beatError)
        }
    }

    @Suite struct SoundMusicInferenceCalibrationTests {
        static let genres: [Genre] = [.house, .dubstep, .drumAndBass, .techno, .trap, .synthwave, .rock]

        /// The gallery's classic demo loop (`DemoPattern`: a two-bar build into a six-bar drop, 140 BPM) heard back
        /// through the analyzer: the clock holds 140 through the snare rolls, every kick is heard, and the sections
        /// follow the loop's. Kick precision is low by design: the build's snares sit in the kick bands and sound on
        /// the beat, so they count as kicks.
        @Test func theClassicLoopIsHeardAsItself() {
            let score = InferenceScore.measure(genre: .dubstep, classicLoop: true)
            #expect(score.tempoAgrees, "tempo \(score.heardBPM.map { "\($0)" } ?? "none")")
            #expect(score.tempoShare > 0.9, "tempo share \(score.tempoShare)")
            #expect(score.lockTime.map { $0 < 8 } ?? false, "lock \(score.lockTime.map { "\($0)" } ?? "never")")
            #expect(score.kickRecall > 0.9, "kick recall \(score.kickRecall)")
            #expect(score.dropAgreement > 0.8, "drop agreement \(score.dropAgreement)")
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["INFER_CALIBRATE"] != nil))
        func printScores() {
            print("score classic " + InferenceScore.measure(genre: .dubstep, classicLoop: true).line)
            for genre in Self.genres {
                print("score " + InferenceScore.measure(genre: genre).line)
            }
        }
    }
#endif
