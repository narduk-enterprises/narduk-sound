import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender

// narduk-music render --scenario <file.json> [--seconds 30] [--genre dubstep] [--seed 24301] [--bpm 140] [--variety 0.75] [--varied]
//                     --out <file.wav | file.m4a> [--json]
//
// Renders a scenario offline: no audio device, nothing on the speakers. Exit codes: 0 rendered, 64 bad usage,
// 65 bad scenario, 74 write failed. Diagnostics go to stderr; `--json` prints a result object on stdout.

struct Usage: Error, CustomStringConvertible {
    var description: String
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let usage = """
    usage: narduk-music render --scenario <file.json> --out <file.wav|file.m4a>
                               [--seconds N] [--genre NAME] [--seed N] [--bpm N] [--variety 0...1] [--varied] [--json]
    genres: \(Genre.allCases.map(\.rawValue).joined(separator: ", "))
    scenario "notes" play an instrument directly: {"time": 1.5, "instrument": "strum", "pitch": 45, "chord": "minor"}
    note instruments: \(Instrument.allCases.filter { $0.synthCode >= 14 }.map(\.rawValue).joined(separator: ", "))
    strum chords: \(StrumChord.allCases.map(\.rawValue).joined(separator: ", ")); direction: down, up
    """

func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "render" else {
        log(usage)
        return arguments.first == "--help" || arguments.first == "-h" ? 0 : 64
    }
    guard let scenarioPath = value("--scenario", in: arguments), let outPath = value("--out", in: arguments) else {
        log(usage)
        return 64
    }
    var scenario: MusicScenario
    do {
        scenario = try MusicScenario.load(Data(contentsOf: URL(fileURLWithPath: scenarioPath)))
    } catch {
        log("could not read scenario \(scenarioPath): \(error)")
        return 65
    }
    if let text = value("--genre", in: arguments) {
        guard let genre = Genre(rawValue: text) else {
            log("unknown genre \(text)\n\(usage)")
            return 64
        }
        scenario.genre = genre
    }
    if let text = value("--seed", in: arguments) {
        guard let seed = UInt64(text) else {
            log("--seed needs an unsigned integer")
            return 64
        }
        scenario.seed = seed
    }
    if let text = value("--bpm", in: arguments) {
        guard let bpm = Double(text), (60...200).contains(bpm) else {
            log("--bpm needs a number from 60 to 200")
            return 64
        }
        scenario.bpm = bpm
    }
    if let text = value("--variety", in: arguments) {
        guard let variety = Double(text), (0...1).contains(variety) else {
            log("--variety needs a number from 0 to 1")
            return 64
        }
        scenario.variety = variety
    }
    if arguments.contains("--varied") { scenario.varied = true }
    var seconds = scenario.seconds ?? 30
    if let text = value("--seconds", in: arguments) {
        guard let parsed = Double(text), parsed > 0, parsed <= 3_600 else {
            log("--seconds needs a number from 0 to 3600")
            return 64
        }
        seconds = parsed
    }

    let started = Date()
    let audio = OfflineRenderer.render(scenario, seconds: seconds) { done in
        log(String(format: "  %.0f / %.0f s", done, seconds))
    }
    let out = URL(fileURLWithPath: outPath)
    do {
        if out.pathExtension.lowercased() == "m4a" {
            try AudioFileWriter.writeM4A(audio, to: out)
        } else {
            try AudioFileWriter.writeWAV(audio, to: out)
        }
    } catch {
        log("could not write \(outPath): \(error)")
        return 74
    }
    let took = Date().timeIntervalSince(started)
    let fingerprint = String(format: "%016llx", audio.fingerprint)
    log(
        String(
            format: "done: %@  %.1f s, peak %.2f, fingerprint %@, %.1f s to render", outPath, audio.seconds,
            audio.peak, fingerprint, took))
    if arguments.contains("--json") {
        let result: [String: Any] = [
            "out": out.path, "seconds": audio.seconds, "sampleRate": audio.sampleRate, "peak": Double(audio.peak),
            "fingerprint": fingerprint,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
    return 0
}

exit(main())
