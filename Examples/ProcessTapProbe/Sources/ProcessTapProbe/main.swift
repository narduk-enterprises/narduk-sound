import Darwin
import Foundation
import NardukSoundAnalysis

// process-tap-probe: runs a muted Core Audio process tap on one process and reports what it hears.
//
//   list                                        every process Core Audio knows, with its output state
//   music --pid N --seconds S --out f.wav       tap Music.app muted, play, capture S seconds, pause, restore
//   click --out f.wav [--pid N]                 tap an afplay of a silent-padded click track, measure latency
//
// Nothing here changes an output device, a volume or a Music setting, and nothing opens a window.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else {
        return nil
    }
    return CommandLine.arguments[index + 1]
}

@discardableResult
func shell(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { fail("cannot run \(launchPath): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func osascript(_ script: String) -> String { shell("/usr/bin/osascript", ["-e", script]) }

func db(_ linear: Double) -> Double { linear > 1e-9 ? 20 * log10(linear) : -180 }

func writeWAV(floatStereo samples: [Float], sampleRate: Double, to path: String) throws {
    let frames = samples.count / 2
    var data = Data()
    func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let byteCount = UInt32(frames * 2 * 4)
    data.append(contentsOf: Array("RIFF".utf8))
    put(UInt32(36) + byteCount)
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    put(UInt32(16))
    put(UInt16(3))
    put(UInt16(2))
    put(UInt32(sampleRate))
    put(UInt32(sampleRate) * 8)
    put(UInt16(8))
    put(UInt16(32))
    data.append(contentsOf: Array("data".utf8))
    put(byteCount)
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: URL(fileURLWithPath: path))
}

func hostSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(ticks) * Double(info.numer) / Double(info.denom) / 1e9
}

struct Stats {
    var rmsDB = 0.0, peakDB = 0.0
    var perSecondRMS: [Double] = []
}

func stats(_ stereo: [Float], sampleRate: Double) -> Stats {
    var sum = 0.0
    var peak = 0.0
    for sample in stereo {
        let v = Double(sample)
        sum += v * v
        peak = max(peak, abs(v))
    }
    var result = Stats(rmsDB: db((sum / Double(max(stereo.count, 1))).squareRoot()), peakDB: db(peak))
    let secondFrames = Int(sampleRate) * 2
    var start = 0
    while start + secondFrames <= stereo.count {
        var s = 0.0
        for i in start..<(start + secondFrames) { s += Double(stereo[i]) * Double(stereo[i]) }
        result.perSecondRMS.append(db((s / Double(secondFrames)).squareRoot()))
        start += secondFrames
    }
    return result
}

struct SpectrumSummary {
    var bass = 0.0, mid = 0.0, high = 0.0, centroidHz = 0.0
    var chroma = [Double](repeating: 0, count: 12)
    var loudFrameFraction = 0.0
    var frames = 0
}

/// Polls `source` on a 60 Hz clock for `seconds`, folding the frames into an average spectrum.
func listen(to source: ProcessTapSource, seconds: Double) -> SpectrumSummary {
    var summary = SpectrumSummary()
    var meanSpectrum = [Double](repeating: 0, count: SoundFrame.spectrumCount)
    var lastSequence: UInt64 = 0
    var loud = 0
    let began = Date()
    while Date().timeIntervalSince(began) < seconds {
        let frame = source.poll(time: Date().timeIntervalSince(began))
        if frame.sequence != lastSequence {
            lastSequence = frame.sequence
            summary.frames += 1
            if frame.rmsDB > -60 { loud += 1 }
            for i in 0..<meanSpectrum.count { meanSpectrum[i] += Double(frame.spectrum[i]) }
            for i in 0..<12 { summary.chroma[i] += Double(frame.chroma[i]) }
        }
        Thread.sleep(forTimeInterval: 1.0 / 60)
    }
    guard summary.frames > 0 else { return summary }
    let analyzer = SpectrumAnalyzer(sampleRate: source.sampleRate)
    var weighted = 0.0
    var total = 0.0
    for i in 0..<meanSpectrum.count {
        meanSpectrum[i] /= Double(summary.frames)
        let hz = Double(analyzer.centerFrequency(ofBand: i))
        if hz < 250 {
            summary.bass += meanSpectrum[i]
        } else if hz < 2_000 {
            summary.mid += meanSpectrum[i]
        } else {
            summary.high += meanSpectrum[i]
        }
        weighted += hz * meanSpectrum[i]
        total += meanSpectrum[i]
    }
    summary.centroidHz = total > 0 ? weighted / total : 0
    for i in 0..<12 { summary.chroma[i] /= Double(summary.frames) }
    summary.loudFrameFraction = Double(loud) / Double(summary.frames)
    return summary
}

func report(_ stereo: [Float], sampleRate: Double, summary: SpectrumSummary) {
    let s = stats(stereo, sampleRate: sampleRate)
    print(
        String(
            format: "capture: %d frames @ %.0f Hz, RMS %.1f dBFS, peak %.1f dBFS", stereo.count / 2, sampleRate,
            s.rmsDB, s.peakDB))
    print("RMS per 2 s block (dBFS): " + s.perSecondRMS.map { String(format: "%.1f", $0) }.joined(separator: " "))
    print(
        String(format: "analyzer frames %d, %.0f%% above -60 dB RMS", summary.frames, summary.loudFrameFraction * 100))
    print(
        String(
            format:
                "mean band energy (0...1 scale, sum over bands): bass<250Hz %.2f, mid 250-2k %.2f, high>2k %.2f; centroid %.0f Hz",
            summary.bass, summary.mid, summary.high, summary.centroidHz))
    print("mean chroma C..B: " + summary.chroma.map { String(format: "%.2f", $0) }.joined(separator: " "))
}

let command = CommandLine.arguments.dropFirst().first ?? "help"

switch command {
case "list":
    for p in ProcessTapSource.audioProcesses().sorted(by: { $0.pid < $1.pid }) {
        print("obj \(p.objectID)\tpid \(p.pid)\t\(p.isRunningOutput ? "OUTPUT" : "idle")\t\(p.bundleID)")
    }

case "music":
    guard let pidText = argument("--pid"), let pid = Int32(pidText) else { fail("music needs --pid N") }
    let seconds = Double(argument("--seconds") ?? "20") ?? 20
    let out = argument("--out")
    let source = ProcessTapSource(pid: pid, mute: true, recordSeconds: seconds + 4)

    // Remember Music's state so it can be put back. Nothing is activated and no setting is touched.
    let wasState = osascript("tell application \"Music\" to get player state")
    let position = osascript("tell application \"Music\" to get player position")
    print("music before: state=\(wasState) position=\(position)")
    print(
        "track: "
            + osascript(
                "tell application \"Music\" to get {class, name, artist, album, kind, cloud status, duration} of current track"
            ))

    guard ProcessTapSource.processObject(forPID: pid) != nil else {
        fail(
            "pid \(pid) has no Core Audio process object while \(wasState); cannot tap before playing (nothing was played)",
            code: 2)
    }
    do { try source.start() } catch { fail("start failed: \(error)", code: 3) }
    print(
        String(
            format: "tap up: reads muted=%@ rate=%.0f latencyFrames=%d bufferFrames=%d presentationLatency=%.1f ms",
            String(describing: source.tapReadsMuted), source.sampleRate, source.latencyFrames, source.bufferFrames,
            source.presentationLatency * 1000))
    guard source.tapReadsMuted == true else {
        source.stop()
        fail("tap does not read muted; not playing", code: 4)
    }
    Thread.sleep(forTimeInterval: 1.0)
    print("IOProc callbacks while idle (an idle process may deliver none): \(source.callbackCount)")

    if wasState != "playing" { _ = osascript("tell application \"Music\" to play") }
    // Wait (briefly) for Music to start rendering through the tap.
    var rendering: [AudioProcessInfo] = []
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.05)
        rendering = ProcessTapSource.audioProcesses().filter { $0.isRunningOutput }
        if rendering.contains(where: { $0.pid == pid }) && source.callbackCount > 0 { break }
    }
    print("music playing: state=\(osascript("tell application \"Music\" to get player state"))")
    print("processes rendering output: " + rendering.map { "\($0.pid) \($0.bundleID)" }.joined(separator: ", "))
    print("IOProc callbacks once playing: \(source.callbackCount)")
    if !rendering.contains(where: { $0.pid == pid }) || source.callbackCount == 0 {
        _ = osascript("tell application \"Music\" to pause")
        source.stop()
        fail(
            "pid \(pid) is not rendering output or the tap is not live; the tap may not mute the real renderer. Paused and stopped.", code: 7
        )
    }
    let summary = listen(to: source, seconds: seconds)
    if wasState != "playing" { _ = osascript("tell application \"Music\" to pause") }
    Thread.sleep(forTimeInterval: 0.3)
    let stereo = source.recordedStereo()
    let rate = source.sampleRate
    let aggregate = source.aggregateUID
    source.stop()
    print("aggregate \(aggregate ?? "-") torn down; callbacks recorded: \(stereo.count / 2) frames")
    _ = osascript("tell application \"Music\" to set player position to \(position)")
    print(
        "music after: state=\(osascript("tell application \"Music\" to get player state")) position=\(osascript("tell application \"Music\" to get player position"))"
    )
    report(stereo, sampleRate: rate, summary: summary)
    if let out {
        try writeWAV(floatStereo: stereo, sampleRate: rate, to: out)
        print("wrote \(out)")
    }

case "click":
    // A control and a latency measurement: afplay plays 2.0 s of silence, then four 12 ms 1 kHz clicks 1 s apart. The
    // tap is created during the silent pad (so nothing is ever audible) and mutes afplay.
    let clickRate = 48_000
    let padSeconds = 2.0
    let total = Int(Double(clickRate) * (padSeconds + 5))
    var samples = [Float](repeating: 0, count: total * 2)
    var clickOffsets: [Double] = []
    for k in 0..<4 {
        let at = padSeconds + 0.5 + Double(k)
        clickOffsets.append(at)
        let startFrame = Int(at * Double(clickRate))
        for i in 0..<(clickRate * 12 / 1000) {
            let v = Float(
                0.2 * sin(2 * Double.pi * 1_000 * Double(i) / Double(clickRate)) * (i < 48 ? Double(i) / 48 : 1))
            samples[(startFrame + i) * 2] = v
            samples[(startFrame + i) * 2 + 1] = v
        }
    }
    let clickPath = NSTemporaryDirectory() + "process-tap-click-\(getpid()).wav"
    try writeWAV(floatStereo: samples, sampleRate: Double(clickRate), to: clickPath)
    defer { try? FileManager.default.removeItem(atPath: clickPath) }

    let afplay = Process()
    afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    afplay.arguments = [clickPath]
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let launched = mach_absolute_time()
    try afplay.run()
    let pid = afplay.processIdentifier
    var object: UInt32?
    for _ in 0..<80 {
        object = ProcessTapSource.processObject(forPID: pid)
        if object != nil { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    let found = mach_absolute_time()
    guard object != nil else {
        afplay.terminate()
        fail("afplay never got a process object", code: 2)
    }
    let source = ProcessTapSource(pid: pid, mute: true, recordSeconds: padSeconds + 6)
    do { try source.start() } catch {
        afplay.terminate()
        fail("start failed: \(error)", code: 3)
    }
    let tapped = mach_absolute_time()
    let tapDelay = hostSeconds(tapped - launched)
    print(
        String(
            format:
                "afplay pid %d: process object after %.0f ms, tap up %.0f ms after launch (pad is %.0f ms); muted=%@",
            pid, hostSeconds(found - launched) * 1000, tapDelay * 1000, padSeconds * 1000,
            String(describing: source.tapReadsMuted)))
    if tapDelay > padSeconds - 0.3 {
        afplay.terminate()
        source.stop()
        fail("tap came up too late; refusing to let a click out", code: 6)
    }
    guard source.tapReadsMuted == true else {
        afplay.terminate()
        source.stop()
        fail("tap not muted", code: 4)
    }
    let summary = listen(to: source, seconds: padSeconds + 5 - tapDelay)
    afplay.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.3)
    let stereo = source.recordedStereo()
    let rate = source.sampleRate
    let start = source.captureStartHostTime
    source.stop()
    report(stereo, sampleRate: rate, summary: summary)
    print(
        String(
            format: "reported latency: %d frames = %.2f ms, buffer %d frames, presentation %.2f ms",
            source.latencyFrames, source.latencySeconds * 1000, source.bufferFrames, source.presentationLatency * 1000))
    // Find click onsets (first sample above 0.02 after at least 0.3 s of quiet) in the capture.
    var onsets: [Double] = []
    var quietSince = 0
    for i in 0..<(stereo.count / 2) {
        if abs(stereo[i * 2]) > 0.02 {
            if quietSince >= Int(rate * 0.3) { onsets.append(Double(i) / rate) }
            quietSince = 0
        } else {
            quietSince += 1
        }
    }
    let captureStartAfterLaunch = hostSeconds(start &- launched)
    print(
        String(
            format: "capture began %.0f ms after afplay launch; %d click onsets found", captureStartAfterLaunch * 1000,
            onsets.count))
    for (k, onset) in onsets.enumerated() where k < clickOffsets.count {
        let observed = captureStartAfterLaunch + onset
        print(
            String(
                format:
                    "click %d: file offset %.3f s, observed %.3f s after launch -> %.1f ms (afplay startup + path latency, upper bound)",
                k, clickOffsets[k], observed, (observed - clickOffsets[k]) * 1000))
    }
    if let out = argument("--out") {
        try writeWAV(floatStereo: stereo, sampleRate: rate, to: out)
        print("wrote \(out)")
    }

default:
    print("usage: process-tap-probe list | music --pid N [--seconds S] [--out f.wav] | click [--out f.wav]")
}
