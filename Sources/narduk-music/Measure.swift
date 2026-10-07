import Foundation
import NardukMusicCore
import NardukMusicRender

// The measuring tools (narduk-sound#36). Everything renders offline into files: nothing reaches the speakers.
//
// narduk-music abtest (--genre NAME | --scenario <file.json>) --b <options> [--a <options>] --out <dir>
//                     [--seeds 1,2,3 | --count 4 --seed-base 1] [--excerpts transition,groove1,breakdown,groove2]
//                     [--seconds 35] [--from N] [--shuffle-seed N] [--m4a]
// A genre plays ABTest.songPlan and four 35 s excerpts per seed, fixed by the plan before anything renders; a scenario
// plays one clip per seed from --from. The hidden key records each seed's fixture (revision, tempo, mode, character,
// energy timeline, track history, faders, sample rate, scenario, audio and bank hashes).
// narduk-music abscore --key <dir/.key.json> --answers <answers.csv|answers.json>
// narduk-music samey [--tracks 30] [--genres all|a,b] [--seed-base 1] [--threshold 0.15] [--window 24:36]
//                    [--note TEXT] --out <file.json>

let measureUsage = """
           narduk-music abtest (--genre NAME | --scenario <file.json>) --b <options> [--a <options>] --out <dir>
                               [--seeds 1,2,3 | --count 4 --seed-base 1] [--excerpts transition,groove1,breakdown,groove2]
                               [--seconds 35] [--from N] [--shuffle-seed N] [--m4a]
               options: a JSON object over the scenario ('{"variety":0}') or flags ('sampled' or 'sampled=false,wide')
           narduk-music abscore --key <dir/.key.json> --answers <file.csv|file.json>
               answers: clip,prefer,more_real with x, y or same (or a JSON array of {clip, prefer, moreReal})
           narduk-music samey --out <file.json> [--tracks 30] [--genres all|a,b] [--seed-base 1] [--threshold 0.15]
                              [--window 24:36] [--note TEXT]
    """

/// Writes `object` as pretty, key-sorted JSON.
func writeJSON(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
}

func seedList(_ arguments: [String], defaultCount: Int) throws -> [UInt64] {
    if let text = value("--seeds", in: arguments) {
        let seeds = text.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
        guard !seeds.isEmpty else { throw Usage(description: "--seeds needs a comma-separated list of integers") }
        return seeds
    }
    let count: Int = try value("--count", in: arguments).map {
        guard let n = Int($0), (1...100).contains(n) else { throw Usage(description: "--count needs 1 to 100") }
        return n
    } ?? defaultCount
    let base: UInt64 = try value("--seed-base", in: arguments).map {
        guard let n = UInt64($0) else { throw Usage(description: "--seed-base needs an unsigned integer") }
        return n
    } ?? 1
    return (0..<UInt64(count)).map { base + $0 }
}

func positive(_ name: String, in arguments: [String], default fallback: Double, max limit: Double) throws -> Double {
    guard let text = value(name, in: arguments) else { return fallback }
    guard let number = Double(text), number >= 0, number <= limit else {
        throw Usage(description: "\(name) needs a number from 0 to \(limit)")
    }
    return number
}

// MARK: abtest

/// The engine revision: the git commit of the working directory, "-dirty" when it has uncommitted changes.
func engineRevision() -> String {
    func git(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let commit = git(["rev-parse", "HEAD"]) else { return "unknown" }
    return git(["status", "--porcelain", "--untracked-files=no"]).map { $0.isEmpty ? commit : commit + "-dirty" }
        ?? commit
}

/// FNV-1a 64 over the names and bytes of every file in the DSP resource bundle beside the executable (the sample
/// banks), or "none" when there is no bundle.
func bankHash() -> String {
    let directory = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let manager = FileManager.default
    let bundles = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { $0.contains("NardukMusicDSP") }.sorted()
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var files = 0
    func mix(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
    }
    for bundle in bundles {
        let root = directory.appendingPathComponent(bundle)
        let paths = (manager.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
        for path in paths {
            var isDirectory: ObjCBool = false
            let url = root.appendingPathComponent(path)
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                let data = try? Data(contentsOf: url)
            else { continue }
            mix(path.utf8)
            mix(data)
            files += 1
        }
    }
    return files == 0 ? "none" : String(format: "%016llx (%d files)", hash, files)
}

func abtest(_ arguments: [String]) -> Int32 {
    do {
        guard let outPath = value("--out", in: arguments), let bOptions = value("--b", in: arguments) else {
            throw Usage(description: "abtest needs --out <dir> and --b <options>")
        }
        let aOptions = value("--a", in: arguments) ?? ""
        var genre: Genre?
        var base = MusicScenario()
        let source: String
        if let path = value("--scenario", in: arguments) {
            base = try MusicScenario.load(Data(contentsOf: URL(fileURLWithPath: path)))
            source = "scenario \(path)"
        } else if let name = value("--genre", in: arguments) {
            guard let parsed = Genre(rawValue: name) else { throw Usage(description: "unknown genre \(name)") }
            genre = parsed
            source = "song \(name), plan ABTest.songPlan"
        } else {
            throw Usage(description: "abtest needs --genre NAME or --scenario <file.json>")
        }
        let seeds = try seedList(arguments, defaultCount: 4)
        let seconds = try positive("--seconds", in: arguments, default: ABTest.excerptSeconds, max: 600)
        guard seconds > 0 else { throw Usage(description: "--seconds must be above 0") }
        // A song plays the four excerpts, fixed by the plan before any render; a scenario plays one clip per seed.
        var excerpts: [ABTest.Excerpt: Double] = [:]
        if genre != nil {
            excerpts = ABTest.excerptStarts()
            if let text = value("--excerpts", in: arguments) {
                let wanted = try text.split(separator: ",").map {
                    guard let kind = ABTest.Excerpt(rawValue: String($0)) else {
                        throw Usage(description: "unknown excerpt \($0)")
                    }
                    return kind
                }
                excerpts = excerpts.filter { wanted.contains($0.key) }
            }
        }
        let from = try positive("--from", in: arguments, default: 0, max: 3_600)
        let shuffleSeed =
            try value("--shuffle-seed", in: arguments).map {
                guard let n = UInt64($0) else { throw Usage(description: "--shuffle-seed needs an unsigned integer") }
                return n
            } ?? ABTest.shuffleSeed(for: seeds)
        let out = URL(fileURLWithPath: outPath)
        let keyURL = out.appendingPathComponent(".key.json")
        guard !FileManager.default.fileExists(atPath: keyURL.path) else {
            throw Usage(description: "\(keyURL.path) exists: use a new folder for each session")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fileExtension = arguments.contains("--m4a") ? "m4a" : "wav"
        var trials = ABTest.plan(
            seeds: seeds, excerpts: excerpts, from: from, seconds: seconds, shuffleSeed: shuffleSeed)
        let renderSeconds = trials.map { $0.from + $0.seconds }.max() ?? seconds
        var fixtures: [ABTest.Fixture] = []
        for seed in seeds {
            var scenario = base
            if let genre { scenario = ABTest.song(genre: genre, seed: seed) } else { scenario.seed = seed }
            let (audioA, fixtureA) = ABTest.render(
                try ABTest.applying(aOptions, to: scenario), side: .a, seconds: renderSeconds)
            let (audioB, fixtureB) = ABTest.render(
                try ABTest.applying(bOptions, to: scenario), side: .b, seconds: renderSeconds)
            fixtures += [fixtureA, fixtureB]
            for index in trials.indices where trials[index].seed == seed {
                let trial = trials[index]
                // Matched on the excerpt itself: gain only, never peak-normalised, no limiter on either side.
                let pair = IntegratedLoudness.match(
                    ABTest.excerpt(audioA, from: trial.from, seconds: trial.seconds),
                    ABTest.excerpt(audioB, from: trial.from, seconds: trial.seconds))
                guard pair.difference <= 0.5 else {
                    log(String(format: "trial %@: loudness match missed by %.2f LU", trial.id, pair.difference))
                    return 70
                }
                trials[index].loudnessA = pair.loudnessA
                trials[index].loudnessB = pair.loudnessB
                trials[index].gainA = pair.gainA
                trials[index].gainB = pair.gainB
                trials[index].matchedDifference = pair.difference
                let clips = trial.x == .a ? [("x", pair.a), ("y", pair.b)] : [("x", pair.b), ("y", pair.a)]
                for (name, audio) in clips {
                    let url = out.appendingPathComponent("\(trial.id)-\(name).\(fileExtension)")
                    if fileExtension == "m4a" {
                        try AudioFileWriter.writeM4A(audio, to: url)
                    } else {
                        try AudioFileWriter.writeWAV(audio, to: url)
                    }
                }
            }
            log("  seed \(seed): A \(fixtureA.audioFingerprint), B \(fixtureB.audioFingerprint)")
        }
        let key = ABTest.Key(
            source: source, revision: engineRevision(), bankHash: bankHash(), optionsA: aOptions,
            optionsB: bOptions, shuffleSeed: shuffleSeed, trials: trials, fixtures: fixtures)
        try writeJSON(key, to: keyURL)
        let template = "clip,prefer,more_real\n" + trials.map { "\($0.id),," }.joined(separator: "\n") + "\n"
        try Data(template.utf8).write(to: out.appendingPathComponent("answers.csv"))
        log(
            "done: \(trials.count) trials (\(trials.count * 2) clips) in \(out.path); fill answers.csv with x, y or "
                + "same, then run abscore. The key is .key.json: do not open it before answering.")
        return 0
    } catch let error as Usage {
        log("\(error)\n\(usage)")
        return 64
    } catch {
        log("abtest failed: \(error)")
        return 74
    }
}

// MARK: abscore

func abscore(_ arguments: [String]) -> Int32 {
    guard let keyPath = value("--key", in: arguments), let answersPath = value("--answers", in: arguments) else {
        log("abscore needs --key <dir/.key.json> and --answers <file>\n\(usage)")
        return 64
    }
    do {
        let key = try JSONDecoder().decode(ABTest.Key.self, from: Data(contentsOf: URL(fileURLWithPath: keyPath)))
        let answers = try ABTest.answers(from: Data(contentsOf: URL(fileURLWithPath: answersPath)))
        let score = ABTest.score(key: key, answers: answers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(score) + Data("\n".utf8))
        log(score.verdict)
        return 0
    } catch {
        log("abscore failed: \(error)")
        return 65
    }
}

// MARK: samey

/// The samey JSON file.
struct SameyFile: Encodable {
    var kind = "narduk-sound samey metric (narduk-sound#36)"
    var status = "a measurement of the code it ran on, not an approved or blessed reference"
    var use = "report only: a near-duplicate score never evicts a track or a repeating motif on its own"
    var note: String
    var measuredAt: String
    var tracksPerGenre: Int
    var seedBase: UInt64
    var variety: Double
    var audioWindowSeconds: SameyMetric.AudioWindow
    var threshold: Double
    var distance: String
    var scales: [String: Double]
    var cpuSeconds: Double
    var genres: [SameyReport]
}

func samey(_ arguments: [String]) -> Int32 {
    do {
        guard let outPath = value("--out", in: arguments) else { throw Usage(description: "samey needs --out") }
        let tracks: Int = try value("--tracks", in: arguments).map {
            guard let n = Int($0), (2...1_000).contains(n) else { throw Usage(description: "--tracks needs 2 to 1000") }
            return n
        } ?? 30
        let seedBase: UInt64 = try value("--seed-base", in: arguments).map {
            guard let n = UInt64($0) else { throw Usage(description: "--seed-base needs an unsigned integer") }
            return n
        } ?? 1
        let threshold = try positive("--threshold", in: arguments, default: 0.15, max: 1)
        var window = SameyMetric.AudioWindow()
        if let text = value("--window", in: arguments) {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] >= 0, parts[1] > parts[0], parts[1] <= 600 else {
                throw Usage(description: "--window needs start:end in seconds, like 24:36")
            }
            window = SameyMetric.AudioWindow(start: parts[0], end: parts[1])
        }
        var genres = Genre.allCases
        if let text = value("--genres", in: arguments), text != "all" {
            genres = try text.split(separator: ",").map {
                guard let genre = Genre(rawValue: String($0)) else { throw Usage(description: "unknown genre \($0)") }
                return genre
            }
        }
        let clock = ProcessInfo.processInfo.systemUptime
        let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        var reports: [SameyReport] = []
        for genre in genres {
            let features = (0..<UInt64(tracks)).map { SameyMetric.features(genre: genre, seed: seedBase + $0, window: window) }
            let report = SameyReport(genre: genre, features: features, threshold: threshold)
            reports.append(report)
            log(
                String(
                    format: "  %-14@ nn %.3f  clusters %d/%d (largest %d)  bass %d  combos %d  forms %d  fills %.1f  tempo %.0f-%.0f",
                    genre.rawValue, report.meanNearestNeighbour, report.clusters, report.tracks,
                    report.largestCluster, report.distinctBassPatches, report.distinctPatchCombinations,
                    report.distinctForms, report.meanFillBarsPerTrack, report.tempo.min, report.tempo.max))
        }
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1e9
        let file = SameyFile(
            note: value("--note", in: arguments) ?? "", measuredAt: ISO8601DateFormatter().string(from: Date()),
            tracksPerGenre: tracks, seedBase: seedBase, variety: SongSettings().variety, audioWindowSeconds: window,
            threshold: threshold,
            distance: "mean of nine group distances, each 0...1 on fixed scales (TrackFeatures.distance)",
            scales: TrackFeatures.scales, cpuSeconds: (cpu * 10).rounded() / 10, genres: reports)
        try writeJSON(file, to: URL(fileURLWithPath: outPath))
        log(
            String(
                format: "done: %@  %d genres x %d tracks, %.0f s wall, %.0f s CPU", outPath, genres.count, tracks,
                ProcessInfo.processInfo.systemUptime - clock, cpu))
        return 0
    } catch let error as Usage {
        log("\(error)\n\(usage)")
        return 64
    } catch {
        log("samey failed: \(error)")
        return 74
    }
}
