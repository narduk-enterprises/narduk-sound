import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender

// narduk-music abtest | abscore | samey: the measuring tools (narduk-sound#36), see Measure.swift.
// narduk-music render --scenario <file.json> [--seconds 30] [--genre dubstep] [--seed 24301] [--bpm 140] [--variety 0.75] [--varied]
//                     [--song] [--only kick,keys/11] [--notes-out notes.jsonl] --out <file.wav | file.m4a> [--json]
//
// `--song` swaps the scenario for the A/B song plan (intro, build, drop, breakdown, build, drop) of its genre and seed,
// so a render leaves the intro. `--only` keeps the listed parts (an instrument, or instrument/voice) and silences the
// rest without changing what the conductor writes, which renders a stem. `--notes-out` logs every note the conductor
// writes, one JSON object a line. The record-quality scorer (tools/record-loop) reads all three.
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
                               [--song] [--only PART,PART] [--notes-out FILE]
    parts for --only: an instrument (kick) or an instrument and voice (keys/11)
    \(measureUsage)
    genres: \(Genre.allCases.map(\.rawValue).joined(separator: ", "))
    scenario "notes" play an instrument directly: {"time": 1.5, "instrument": "strum", "pitch": 45, "chord": "minor"}
    note instruments: \(Instrument.allCases.filter { $0.synthCode >= 14 }.map(\.rawValue).joined(separator: ", "))
    strum chords: \(StrumChord.allCases.map(\.rawValue).joined(separator: ", ")); direction: down, up
    """

/// `--notes-out`: one JSON line a conductor note, written as the render asks for it.
final class NoteLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    /// Follows the renderer's tempo so a note's time is in seconds.
    var secondsPerStep: Double {
        get { lock.withLock { stepSeconds } }
        set { lock.withLock { stepSeconds = newValue } }
    }
    private var stepSeconds = 0.0

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let handle = FileHandle(forWritingAtPath: path)
        else { return nil }
        self.handle = handle
    }

    func write(_ note: ScheduledNote) {
        lock.withLock {
            var line: [String: Any] = [
                "step": note.step, "t": Double(note.step) * stepSeconds, "i": note.instrument.rawValue,
                "vel": note.velocity, "len": note.params.lengthSteps,
            ]
            if let pitch = note.params.pitch { line["p"] = pitch }
            if let voice = note.params.voice { line["v"] = voice }
            if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                handle.write(data + Data("\n".utf8))
            }
        }
    }

    func close() { try? handle.close() }
}

func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "abtest": return abtest(arguments)
    case "abscore": return abscore(arguments)
    case "samey": return samey(arguments)
    default: break
    }
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
    if arguments.contains("--song") {
        var song = ABTest.song(genre: scenario.genre ?? .house, seed: scenario.seed ?? 1)
        song.variety = scenario.variety
        song.flags = scenario.flags
        scenario = song
    }
    let only = value("--only", in: arguments).map { Set($0.split(separator: ",").map(String.init)) }
    var noteLog: NoteLog?
    if let path = value("--notes-out", in: arguments) {
        guard let opened = NoteLog(path: path) else {
            log("could not open \(path) for --notes-out")
            return 74
        }
        opened.secondsPerStep = scenario.settings().secondsPerStep
        noteLog = opened
    }
    var seconds = scenario.seconds ?? 30
    if let text = value("--seconds", in: arguments) {
        guard let parsed = Double(text), parsed > 0, parsed <= 3_600 else {
            log("--seconds needs a number from 0 to 3600")
            return 64
        }
        seconds = parsed
    }

    let started = Date()
    var filter: (@Sendable (ScheduledNote) -> Bool)?
    if only != nil || noteLog != nil {
        filter = { [noteLog] (note: ScheduledNote) -> Bool in
            noteLog?.write(note)
            guard let only else { return true }
            let part = note.instrument.rawValue
            if only.contains(part) { return true }
            guard let voice = note.params.voice else { return false }
            return only.contains("\(part)/\(voice)")
        }
    }
    var observe: ((OfflineRenderer) -> Void)?
    if let noteLog { observe = { renderer in noteLog.secondsPerStep = renderer.settings.secondsPerStep } }
    let audio = OfflineRenderer.render(
        scenario, seconds: seconds,
        progress: { done in log(String(format: "  %.0f / %.0f s", done, seconds)) },
        observe: observe, filter: filter)
    noteLog?.close()
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
