import Foundation
import NardukMusicCore
import NardukSoundAnalysis

/// What the visualizers need over a whole track, recorded once so another device can replay it against the track's
/// playback time with no audio access: a Mac analyzes a song (`SoundTimelineRecorder`), an Apple TV that is only
/// *playing* the song (Apple Music) draws from the timeline (`SoundTimelinePlayer`).
///
/// A timeline is a header plus samples on a fixed grid (50 Hz by default). Each sample holds the `MusicContext`
/// essentials `SoundMusicInference` produces (beat position, tempo, section, hit counts, running, wobble cutoff, energy)
/// and a reduced `SoundFrame` (the 64 bands and 12 chroma classes at 8 bits, `rmsDB` and `peakDB` in centi-dB, and the
/// waveform as 32 companded 8-bit points, which the player restores to the 512 the shaders index).
///
/// **Encoding.** `encoded()` is a small binary container: `NSTL`, a UInt16 version, a UInt32 header length, the header as
/// sorted-key JSON, then the samples as planar little-endian blocks (one block per stored field, in the order they
/// are declared in `SoundTimeline`). Planar blocks are what a later compression pass (or a CDN's gzip) likes best, the
/// JSON header leaves room to add fields without breaking a version-1 reader, and decoding needs Foundation only, so it
/// runs on tvOS, iOS and macOS alike. `Codable` is also supported (the samples travel as one base64 `Data`), for a plist
/// or JSON carrier; `encoded()` is the format to store.
///
/// Not recorded in version 1: the notes (`heldNotes`, `noteCounts`, key). `SoundMusicInference` leaves them empty and
/// the musical tiles fall back to the analysis chroma, which is recorded. `wobblePhase` and `phraseProgress` are derived
/// from the beat position when played, as the inference derives them.
public struct SoundTimeline: Sendable, Equatable, Codable {
    public static let formatVersion = 1
    /// Samples per second of the default grid: the analysis rate (`OfflineRenderer.tickRate`, a display poll), so a sample
    /// is exactly the frame and context the live path saw and nothing is resampled. At 50 Hz a hit lands up to a frame off
    /// (a 60 Hz display never lines up with a 50 Hz grid); see the PR for the measurement.
    public static let defaultGridRate = 60.0
    /// Points of the stored waveform (box means of 16 samples); the player restores the 512 the shaders index. Time
    /// matters more than detail: the Scope's frame-to-frame motion follows the live waveform (r 0.97) when every frame
    /// has one, and not (r 0.6) when a 64-point waveform is stored every second frame. 32 points every frame keeps four
    /// minutes at 60 Hz under 2 MB (64 points would take 2.26 MB).
    public static let waveformPoints = 32
    /// Every sample carries a waveform.
    public static let defaultWaveformEvery = 1

    /// The constants of `SoundMusicInference` the timeline was inferred with.
    public struct InferenceParameters: Sendable, Equatable, Codable {
        public var gridRate: Double
        public var minBPM: Double
        public var maxBPM: Double
        public var defaultBPM: Double
        public var tempoInterval: Double
        public var agreementsToLock: Int
        public var agreementsToSwitch: Int
        public var silenceDB: Float

        /// The running `SoundMusicInference`'s constants.
        public static var current: InferenceParameters {
            InferenceParameters(
                gridRate: SoundMusicInference.gridRate, minBPM: SoundMusicInference.minBPM,
                maxBPM: SoundMusicInference.maxBPM, defaultBPM: SoundMusicInference.defaultBPM,
                tempoInterval: SoundMusicInference.tempoInterval,
                agreementsToLock: SoundMusicInference.agreementsToLock,
                agreementsToSwitch: SoundMusicInference.agreementsToSwitch, silenceDB: SoundMusicInference.silenceDB)
        }
    }

    public struct Header: Sendable, Equatable, Codable {
        public var formatVersion: Int
        /// Whatever names the track to the app that plays it (a file name, an Apple Music catalog id).
        public var trackID: String
        /// Seconds of audio analyzed.
        public var duration: Double
        /// Samples per second; sample `k` is the state at `k / gridRate` seconds into the track.
        public var gridRate: Double
        public var sampleCount: Int
        /// The tempo the beat clock held when the recording ended; nil when it never locked (or the source had none).
        public var tempoBPM: Double?
        /// The `Instrument.index` of each recorded hit lane, ascending: the lanes that ever fired.
        public var hitLanes: [Int]
        public var waveformPoints: Int
        /// The waveform is stored with sample 0, `waveformEvery`, 2 * `waveformEvery`, ...
        public var waveformEvery: Int
        public var stepsPerBar: Int
        public var stepsPerPhrase: Int
        public var buildThreshold: Float
        public var dropThreshold: Float
        /// The analysis the frames came from.
        public var analysisSampleRate: Double
        public var analysisRate: Double
        /// The inference parameters, nil when the context came from a source other than `SoundMusicInference`.
        public var inference: InferenceParameters?
    }

    public private(set) var header: Header

    // Planar samples, `header.sampleCount` of each (times the stride in the name).
    var spectrum: [UInt8]  // x 64, value / 255
    var chroma: [UInt8]  // x 12, value / 255
    var rmsCentiDB: [Int16]
    var peakCentiDB: [Int16]
    /// Bits 0 ... 2 the section (`sectionCode`), bit 3 `isRunning`, bit 4 `dropQueued`.
    var flags: [UInt8]
    var cutoff: [UInt8]  // wobbleCutoff, value / 255
    var energy: [UInt8]  // value / 255
    /// The beat clock in 16th steps, with the fraction through the current one.
    var position: [Float]
    /// `secondsPerStep` in units of `stepUnit` seconds.
    var stepDuration: [UInt16]
    /// Hits since the previous sample on each of `header.hitLanes`, saturating at 255 with the rest carried forward.
    var hits: [UInt8]  // x hitLanes.count
    /// Companded: `sign * sqrt(|x|) * 127`, so a quiet waveform keeps its shape.
    var waveform: [Int8]  // x waveformPoints, for every `waveformEvery`-th sample

    public static let stepUnit = 4e-6
    static let bandCount = SoundFrame.spectrumCount
    static let chromaCount = SoundFrame.chromaCount

    init(
        header: Header, spectrum: [UInt8], chroma: [UInt8], rmsCentiDB: [Int16], peakCentiDB: [Int16], flags: [UInt8],
        cutoff: [UInt8], energy: [UInt8], position: [Float], stepDuration: [UInt16], hits: [UInt8], waveform: [Int8]
    ) {
        self.header = header
        self.spectrum = spectrum
        self.chroma = chroma
        self.rmsCentiDB = rmsCentiDB
        self.peakCentiDB = peakCentiDB
        self.flags = flags
        self.cutoff = cutoff
        self.energy = energy
        self.position = position
        self.stepDuration = stepDuration
        self.hits = hits
        self.waveform = waveform
    }

    public var sampleCount: Int { header.sampleCount }
    public var duration: Double { header.duration }
    public var gridRate: Double { header.gridRate }

    /// How many samples carry a waveform.
    static func waveformSamples(count: Int, every: Int) -> Int { (count + max(every, 1) - 1) / max(every, 1) }

    /// Bytes of the sample payload (the encoded file is this plus the JSON header and 10 bytes).
    public var payloadByteCount: Int { Self.payloadByteCount(header) }

    static func payloadByteCount(_ header: Header) -> Int {
        let n = header.sampleCount
        let perSample = bandCount + chromaCount + 2 + 2 + 1 + 1 + 1 + 4 + 2 + header.hitLanes.count
        return n * perSample + waveformSamples(count: n, every: header.waveformEvery) * header.waveformPoints
    }

    // MARK: Quantization

    static func unit(_ value: Float) -> UInt8 {
        value.isFinite ? UInt8((min(max(value, 0), 1) * 255).rounded()) : 0
    }

    static func centiDB(_ db: Float) -> Int16 {
        db.isFinite ? Int16((min(max(db, -300), 300) * 100).rounded()) : Int16(SoundFrame.silenceDB * 100)
    }

    static func compand(_ value: Float) -> Int8 {
        guard value.isFinite else { return 0 }
        let magnitude = min(abs(value), 1).squareRoot()
        return Int8((value < 0 ? -magnitude : magnitude) * 127 + (value < 0 ? -0.5 : 0.5))
    }

    static func expand(_ code: Int8) -> Float {
        let magnitude = Float(abs(Int(code))) / 127
        let value = magnitude * magnitude
        return code < 0 ? -value : value
    }

    static func sectionCode(_ section: SongSection) -> UInt8 {
        switch section {
        case .intro: 0
        case .build: 1
        case .drop: 2
        case .breakdown: 3
        case .drop2: 4
        }
    }

    static func section(code: UInt8) -> SongSection {
        switch code & 7 {
        case 1: .build
        case 2: .drop
        case 3: .breakdown
        case 4: .drop2
        default: .intro
        }
    }

    // MARK: Binary container

    public enum DecodingError: Error, Equatable {
        case notATimeline
        case unsupportedVersion(Int)
        case truncated
        case inconsistent(String)
    }

    static let magic: [UInt8] = Array("NSTL".utf8)

    /// The compact binary form: byte for byte the same for the same timeline.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(header)
        var data = Data()
        data.reserveCapacity(10 + json.count + payloadByteCount)
        data.append(contentsOf: Self.magic)
        Self.appendLE(&data, [UInt16(Self.formatVersion)])
        Self.appendLE(&data, [UInt32(json.count)])
        data.append(json)
        data.append(payload())
        return data
    }

    /// Reads what `encoded()` wrote. Throws `DecodingError` for another format, a newer version or damaged data.
    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes[0..<4]) == Self.magic else { throw DecodingError.notATimeline }
        let version = Int(Self.readLE(UInt16.self, bytes, at: 4, count: 1)[0])
        guard version == Self.formatVersion else { throw DecodingError.unsupportedVersion(version) }
        let headerLength = Int(Self.readLE(UInt32.self, bytes, at: 6, count: 1)[0])
        guard bytes.count >= 10 + headerLength else { throw DecodingError.truncated }
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: Data(bytes[10..<(10 + headerLength)]))
        } catch {
            throw DecodingError.inconsistent("header: \(error)")
        }
        try self.init(header: header, payload: Array(bytes[(10 + headerLength)...]))
    }

    init(header: Header, payload: [UInt8]) throws {
        guard header.formatVersion == Self.formatVersion else {
            throw DecodingError.unsupportedVersion(header.formatVersion)
        }
        let n = header.sampleCount
        let lanes = header.hitLanes.count
        guard n >= 0, header.waveformPoints > 0, header.waveformEvery > 0, header.gridRate > 0,
            header.hitLanes.allSatisfy({ (0..<HitCounters.laneCount).contains($0) })
        else { throw DecodingError.inconsistent("header values out of range") }
        let expected = Self.payloadByteCount(header)
        guard payload.count >= expected else { throw DecodingError.truncated }
        guard payload.count == expected else { throw DecodingError.inconsistent("trailing bytes") }
        var offset = 0
        func take<T: FixedWidthInteger>(_ type: T.Type, _ count: Int) -> [T] {
            defer { offset += count * MemoryLayout<T>.size }
            return Self.readLE(type, payload, at: offset, count: count)
        }
        self.header = header
        spectrum = take(UInt8.self, n * Self.bandCount)
        chroma = take(UInt8.self, n * Self.chromaCount)
        rmsCentiDB = take(Int16.self, n)
        peakCentiDB = take(Int16.self, n)
        flags = take(UInt8.self, n)
        cutoff = take(UInt8.self, n)
        energy = take(UInt8.self, n)
        position = take(UInt32.self, n).map { Float(bitPattern: $0) }
        stepDuration = take(UInt16.self, n)
        hits = take(UInt8.self, n * lanes)
        waveform = take(Int8.self, Self.waveformSamples(count: n, every: header.waveformEvery) * header.waveformPoints)
    }

    private func payload() -> Data {
        var data = Data()
        data.reserveCapacity(payloadByteCount)
        data.append(contentsOf: spectrum)
        data.append(contentsOf: chroma)
        Self.appendLE(&data, rmsCentiDB)
        Self.appendLE(&data, peakCentiDB)
        data.append(contentsOf: flags)
        data.append(contentsOf: cutoff)
        data.append(contentsOf: energy)
        Self.appendLE(&data, position.map { $0.bitPattern })
        Self.appendLE(&data, stepDuration)
        data.append(contentsOf: hits)
        data.append(contentsOf: waveform.map { UInt8(bitPattern: $0) })
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ values: [T]) {
        values.map { $0.littleEndian }.withUnsafeBytes { data.append(contentsOf: $0) }
    }

    private static func readLE<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int, count: Int)
        -> [T]
    {
        bytes.withUnsafeBytes { raw in
            (0..<count).map {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<T>.size, as: T.self))
            }
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case header, samples }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(header, forKey: .header)
        try container.encode(payload(), forKey: .samples)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let header = try container.decode(Header.self, forKey: .header)
        let samples = try container.decode(Data.self, forKey: .samples)
        try self.init(header: header, payload: [UInt8](samples))
    }
}
