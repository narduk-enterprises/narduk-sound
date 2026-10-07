import Foundation
import NardukMusicCore

/// What the lights were doing while a song was recorded, so the same picture can be drawn again later (a video of
/// the song). The audio itself is not here: a video export re-analyzes the recorded file. This holds what the audio
/// cannot tell: the music's own context (hit counters, the beat clock, the section), which light was showing, its
/// palette look and the calm setting, each stamped in seconds from the start of the recording.
public struct SoundVisualTimeline: Sendable, Equatable {
    /// One snapshot of the music, `time` seconds into the recording.
    public struct Sample: Sendable, Equatable {
        public var time: Double
        public var music: MusicContext

        public init(time: Double, music: MusicContext) {
            self.time = time
            self.music = music
        }
    }

    /// A change that holds until the next one: a light, a look or the calm setting.
    public struct Change<Value: Sendable & Equatable>: Sendable, Equatable {
        public var time: Double
        public var value: Value

        public init(time: Double, value: Value) {
            self.time = time
            self.value = value
        }
    }

    public var samples: [Sample] = []
    /// The light's id, as the app names it (the exporter asks the app what to draw for it).
    public var lights: [Change<String>] = []
    public var looks: [Change<SoundPaletteLook>] = []
    public var calm: [Change<Bool>] = []

    public init() {}

    /// The value of `changes` in force at `time`: the last change at or before it, else the first, else nil.
    public static func value<Value>(of changes: [Change<Value>], at time: Double) -> Value? {
        guard let first = changes.first else { return nil }
        var low = 0
        var high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? first.value : changes[low - 1].value
    }

    /// The index of the last sample at or before `time`, or nil when there is none.
    public func sampleIndex(at time: Double) -> Int? {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// The music at `time`: the last snapshot at or before it, or nil before the first one or after a gap longer
    /// than `maxGap` (the music was not sampled then, so the lights fall back to the audio alone).
    public func music(at time: Double, maxGap: Double = 0.5) -> MusicContext? {
        guard let index = sampleIndex(at: time), time - samples[index].time <= maxGap else { return nil }
        return samples[index].music
    }
}

/// Builds a `SoundVisualTimeline` while a song records. Sampling is the caller's (a timer at `interval`, or every
/// display frame); `record` drops samples closer together than `interval`, and the changes drop repeats.
public struct SoundVisualTimelineRecorder: Sendable {
    public private(set) var timeline = SoundVisualTimeline()
    public let interval: Double

    /// The default rate matches the live screen's 60 Hz: the exporter steps the picture at that rate, and a coarser
    /// log visibly shifts lights that integrate the music's motion (the Sun drifted 2.5 levels at 30 Hz, 0.3 at 60).
    public init(interval: Double = 1.0 / 60) {
        self.interval = interval
    }

    public mutating func record(_ music: MusicContext, at time: Double) {
        if let last = timeline.samples.last, time - last.time < interval * 0.95 { return }
        timeline.samples.append(SoundVisualTimeline.Sample(time: max(0, time), music: music))
    }

    public mutating func light(_ id: String, at time: Double) {
        Self.append(id, at: time, to: &timeline.lights)
    }

    public mutating func look(_ look: SoundPaletteLook, at time: Double) {
        Self.append(look, at: time, to: &timeline.looks)
    }

    public mutating func calm(_ calm: Bool, at time: Double) {
        Self.append(calm, at: time, to: &timeline.calm)
    }

    private static func append<Value>(
        _ value: Value, at time: Double, to changes: inout [SoundVisualTimeline.Change<Value>]
    ) {
        if changes.last?.value == value { return }
        changes.append(SoundVisualTimeline.Change(time: max(0, time), value: value))
    }
}

// MARK: - File format

extension SoundVisualTimeline {
    public enum FormatError: Error, Equatable {
        case notATimeline
        case unsupportedVersion(Int)
        case truncated
    }

    static let magic: [UInt8] = Array("NSVT".utf8)
    static let version: UInt8 = 1

    /// A compact binary form (about 330 bytes per sample before compression; a few tens of kilobytes a minute
    /// after it on Apple platforms). Little-endian, versioned.
    public func encoded() -> Data {
        var body = ByteWriter()
        body.u32(UInt32(samples.count))
        for sample in samples {
            body.f64(sample.time)
            Self.write(sample.music, to: &body)
        }
        body.u32(UInt32(lights.count))
        for change in lights {
            body.f64(change.time)
            body.string(change.value)
        }
        body.u32(UInt32(looks.count))
        for change in looks {
            body.f64(change.time)
            let json = (try? JSONEncoder().encode(change.value)) ?? Data()
            body.data(json)
        }
        body.u32(UInt32(calm.count))
        for change in calm {
            body.f64(change.time)
            body.u8(change.value ? 1 : 0)
        }
        var out = Data(Self.magic)
        out.append(Self.version)
        #if canImport(Darwin)
            if let packed = try? (Data(body.bytes) as NSData).compressed(using: .lzfse) as Data {
                out.append(1)
                out.append(packed)
                return out
            }
        #endif
        out.append(0)
        out.append(contentsOf: body.bytes)
        return out
    }

    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, Array(bytes[0..<4]) == Self.magic else { throw FormatError.notATimeline }
        guard bytes[4] == Self.version else { throw FormatError.unsupportedVersion(Int(bytes[4])) }
        var body = Data(bytes[6...])
        if bytes[5] == 1 {
            #if canImport(Darwin)
                guard let unpacked = try? (body as NSData).decompressed(using: .lzfse) as Data else {
                    throw FormatError.truncated
                }
                body = unpacked
            #else
                throw FormatError.unsupportedVersion(Int(bytes[4]))
            #endif
        }
        var reader = ByteReader(bytes: [UInt8](body))
        self.init()
        let sampleCount = try reader.u32()
        samples.reserveCapacity(Int(sampleCount))
        for _ in 0..<sampleCount {
            let time = try reader.f64()
            samples.append(Sample(time: time, music: try Self.readMusic(from: &reader)))
        }
        for _ in 0..<(try reader.u32()) {
            let time = try reader.f64()
            lights.append(Change(time: time, value: try reader.string()))
        }
        for _ in 0..<(try reader.u32()) {
            let time = try reader.f64()
            let json = try reader.data()
            guard let look = try? JSONDecoder().decode(SoundPaletteLook.self, from: json) else {
                throw FormatError.truncated
            }
            looks.append(Change(time: time, value: look))
        }
        for _ in 0..<(try reader.u32()) {
            let time = try reader.f64()
            calm.append(Change(time: time, value: try reader.u8() != 0))
        }
    }

    private static let sections = SongSection.allCases

    private static func write(_ music: MusicContext, to out: inout ByteWriter) {
        out.i64(Int64(music.step))
        out.u8(UInt8(sections.firstIndex(of: music.section) ?? 0))
        out.f32(music.energy)
        out.f32(music.wobblePhase)
        out.f32(music.wobbleCutoff)
        out.u8(music.isRunning ? 1 : 0)
        out.f64(music.secondsPerStep)
        out.i32(Int32(music.stepsPerBar))
        out.i32(Int32(music.stepsPerPhrase))
        out.f32(music.phraseProgress)
        out.f32(music.buildThreshold)
        out.f32(music.dropThreshold)
        out.u8(music.dropQueued ? 1 : 0)
        for lane in 0..<HitCounters.laneCount { out.u32(music.hitCounts.lanes[lane]) }
        out.u64(music.heldNotes.bits.x)
        out.u64(music.heldNotes.bits.y)
        for i in 0..<64 { out.u8(music.noteCounts.low[i]) }
        for i in 0..<64 { out.u8(music.noteCounts.high[i]) }
        out.u8(music.keyPitchClass.map { UInt8($0) } ?? 255)
        out.u8(music.keyIsMinor.map { $0 ? 1 : 0 } ?? 255)
    }

    private static func readMusic(from input: inout ByteReader) throws -> MusicContext {
        var music = MusicContext()
        music.step = Int(try input.i64())
        let section = Int(try input.u8())
        music.section = section < sections.count ? sections[section] : .intro
        music.energy = try input.f32()
        music.wobblePhase = try input.f32()
        music.wobbleCutoff = try input.f32()
        music.isRunning = try input.u8() != 0
        music.secondsPerStep = try input.f64()
        music.stepsPerBar = Int(try input.i32())
        music.stepsPerPhrase = Int(try input.i32())
        music.phraseProgress = try input.f32()
        music.buildThreshold = try input.f32()
        music.dropThreshold = try input.f32()
        music.dropQueued = try input.u8() != 0
        for lane in 0..<HitCounters.laneCount { music.hitCounts.lanes[lane] = try input.u32() }
        music.heldNotes.bits = SIMD2(try input.u64(), try input.u64())
        for i in 0..<64 { music.noteCounts.low[i] = try input.u8() }
        for i in 0..<64 { music.noteCounts.high[i] = try input.u8() }
        let key = try input.u8()
        music.keyPitchClass = key == 255 ? nil : Int(key)
        let minor = try input.u8()
        music.keyIsMinor = minor == 255 ? nil : minor == 1
        return music
    }
}

private struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    mutating func data(_ v: Data) {
        u32(UInt32(v.count))
        bytes.append(contentsOf: v)
    }
    mutating func string(_ v: String) { data(Data(v.utf8)) }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw SoundVisualTimeline.FormatError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func u8() throws -> UInt8 { try take(1).first ?? 0 }
    mutating func u32() throws -> UInt32 {
        try take(4).reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
    mutating func u64() throws -> UInt64 {
        try take(8).reversed().reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func data() throws -> Data { Data(try take(Int(try u32()))) }
    mutating func string() throws -> String { String(decoding: try data(), as: UTF8.self) }
}
