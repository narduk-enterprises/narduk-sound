import Foundation
import NardukMusicCore

/// A recorded instrument in `InstrumentBank` (`Resources/instruments.bin`). The raw value is its slot in the bank.
public enum SampledInstrument: Int, CaseIterable, Sendable {
    case piano, steelDrum, flute, sax, nylonGuitar, shaker, tambourine, snap, conga

    /// The name the bank's manifest uses.
    var bankName: String {
        switch self {
        case .piano: "piano"
        case .steelDrum: "steelDrum"
        case .flute: "flute"
        case .sax: "sax"
        case .nylonGuitar: "nylonGuitar"
        case .shaker: "shaker"
        case .tambourine: "tambourine"
        case .snap: "snap"
        case .conga: "conga"
        }
    }

    /// The instrument a `.keys` note's voice asks for (`KeysVoice.sampledPiano` ... `sampledConga`), or nil.
    public init?(keysVoice voice: Int) {
        switch voice {
        case KeysVoice.sampledPiano: self = .piano
        case KeysVoice.sampledSteelDrum: self = .steelDrum
        case KeysVoice.sampledFlute: self = .flute
        case KeysVoice.sampledSax: self = .sax
        case KeysVoice.sampledNylonGuitar: self = .nylonGuitar
        case KeysVoice.sampledConga: self = .conga
        default: return nil
        }
    }

    /// Hand percussion: one recording per hit, played whole, its pitch left alone, round robin across takes.
    var isPercussion: Bool { self == .shaker || self == .tambourine || self == .snap || self == .conga }

    /// Held for the note's length on the recording's loop (the flute, the sax); everything else rings out.
    var sustains: Bool { self == .flute || self == .sax }

    /// Seconds the note takes to fade once its gate ends (a pluck is damped; a percussion hit is not cut short).
    var releaseSeconds: Float {
        switch self {
        case .piano: 0.35
        case .steelDrum: 0.8  // a pan rings on: a short damp made the hook choppy (Logan, 2026-10-07)
        case .flute: 0.12
        case .sax: 0.1
        case .nylonGuitar: 0.25
        case .shaker, .tambourine, .snap, .conga: 0
        }
    }

    /// Level against the synth voices it replaces.
    var trim: Float {
        // Tropical house is the only genre that plays these, and it is a melody track: the melody sits on top of the
        // kick and the bass (`GenreArrangement.balance`), so the trims run well above the synth voices'.
        switch self {
        case .piano: 5.4
        case .steelDrum: 4.8
        case .flute: 5.4
        case .sax: 4.8
        case .nylonGuitar: 5.4
        case .shaker: 2.7
        case .tambourine: 2.4
        case .snap: 2.4
        case .conga: 2.1
        }
    }
}

/// The recorded instruments behind `KeysVoice.sampledPiano` ... `sampledConga` and `PercussionVoice`: a few seconds
/// of each, at 32 kHz, decoded once into Float (sources and licences in `Resources/LICENSES/Instruments.md`; the bank
/// is built by `scripts/build_instruments.py`). Immutable after loading, so render-thread voices read it without a
/// lock and without allocating.
///
/// Format `NVS2`: the magic, a little-endian UInt32 manifest length, a JSON manifest (`sampleRate`, `instruments`
/// with their `velocitySplit`, `clips` with `instrument`, `root`, `layer`, `offset`, `count`, `loopStart`, `loopEnd`
/// and `index`), then 16-bit PCM. A pitched instrument has a root every minor third; a clip with `loopEnd > 0` holds
/// on `loopStart ..< loopEnd`, its crossfade baked in. A two-layer instrument plays layer 1 at or above its split.
public final class InstrumentBank: @unchecked Sendable {
    public struct Clip: Sendable {
        public var instrument: Int
        public var root: Float
        public var layer: Int
        public var offset: Int
        public var count: Int
        public var loopStart: Int
        public var loopEnd: Int
        public var index: Int
    }

    /// Credit lines for an app's about or acknowledgements screen, one per source (`Resources/LICENSES/Instruments.md`).
    /// The Salamander piano's is required by its licence (CC BY 3.0); the rest are courtesy credits.
    public static let credits: [String] = [
        "Piano samples from Salamander Grand Piano V3 by Alexander Holm (CC BY 3.0), modified.",
        "Flute samples from VSCO 2 Community Edition by Versilian Studios / Sam Gossner (CC0).",
        "Shaker, tambourine and conga samples from the Versilian Community Sample Library (CC0).",
        "Alto sax and nylon guitar samples from the University of Iowa Electronic Music Studios.",
        "Steel drum samples from jSteelDrum by Jeff Learman (Unlicense).",
        "Finger snap by Joma86 on Freesound (CC0).",
    ]

    public let sampleRate: Double
    public let clipCount: Int
    public let totalSamples: Int
    let clips: UnsafeMutablePointer<Clip>
    let pcm: UnsafeMutablePointer<Float>
    /// Per instrument (by raw value): the velocity that switches to layer 1 (0: one layer), the lowest and highest
    /// root, and how many clips it has.
    let splits: UnsafeMutablePointer<Float>
    let lowest: UnsafeMutablePointer<Float>
    let highest: UnsafeMutablePointer<Float>
    let counts: UnsafeMutablePointer<Int>

    private struct Manifest: Decodable {
        struct Instrument: Decodable {
            var name: String
            var velocitySplit: Double
        }
        struct Entry: Decodable {
            var instrument: String
            var root: Double
            var layer: Int
            var offset: Int
            var count: Int
            var loopStart: Int
            var loopEnd: Int
            var index: Int
        }
        var sampleRate: Double
        var instruments: [Instrument]
        var clips: [Entry]
    }

    /// The shipped bank, loaded on first use (a synth core touches it when it is built, so the audio thread never
    /// does). `nil` if the resource is missing or damaged: the sampled voices then play their synth fallbacks.
    public static let shared: InstrumentBank? = {
        guard
            let url = Bundle.module.url(forResource: "instruments", withExtension: "bin", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "instruments", withExtension: "bin"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return InstrumentBank(data: data)
    }()

    /// Parses `NVS2` + little-endian manifest length + JSON manifest + 16-bit PCM. Instruments the manifest names that
    /// this build does not know are skipped.
    public init?(data: Data) {
        guard data.count > 8, data.prefix(4) == Data("NVS2".utf8) else { return nil }
        let manifestLength = data.subdata(in: 4..<8).withUnsafeBytes {
            Int($0.loadUnaligned(as: UInt32.self).littleEndian)
        }
        guard 8 + manifestLength <= data.count,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data.subdata(in: 8..<(8 + manifestLength))),
            manifest.sampleRate > 8_000
        else { return nil }
        let pcmStart = 8 + manifestLength
        let samples = (data.count - pcmStart) / 2
        let kinds = SampledInstrument.allCases.count
        var entries: [Clip] = []
        var split = [Float](repeating: 0, count: kinds)
        var low = [Float](repeating: .greatestFiniteMagnitude, count: kinds)
        var high = [Float](repeating: -.greatestFiniteMagnitude, count: kinds)
        var count = [Int](repeating: 0, count: kinds)
        for i in manifest.instruments {
            if let kind = SampledInstrument.allCases.first(where: { $0.bankName == i.name }) {
                split[kind.rawValue] = Float(i.velocitySplit)
            }
        }
        for e in manifest.clips {
            guard let kind = SampledInstrument.allCases.first(where: { $0.bankName == e.instrument }) else { continue }
            guard e.offset >= 0, e.count > 4, e.offset + e.count <= samples, e.loopStart >= 0, e.loopEnd <= e.count,
                e.loopEnd == 0 || e.loopEnd > e.loopStart + 8, e.layer >= 0, e.layer <= 1
            else { return nil }
            entries.append(
                Clip(
                    instrument: kind.rawValue, root: Float(e.root), layer: e.layer, offset: e.offset, count: e.count,
                    loopStart: e.loopStart, loopEnd: e.loopEnd, index: e.index))
            low[kind.rawValue] = min(low[kind.rawValue], Float(e.root))
            high[kind.rawValue] = max(high[kind.rawValue], Float(e.root))
            count[kind.rawValue] += 1
        }
        guard !entries.isEmpty else { return nil }
        sampleRate = manifest.sampleRate
        clipCount = entries.count
        totalSamples = samples
        clips = .allocate(capacity: entries.count)
        clips.initialize(from: entries, count: entries.count)
        splits = .allocate(capacity: kinds)
        splits.initialize(from: split, count: kinds)
        lowest = .allocate(capacity: kinds)
        lowest.initialize(from: low, count: kinds)
        highest = .allocate(capacity: kinds)
        highest.initialize(from: high, count: kinds)
        counts = .allocate(capacity: kinds)
        counts.initialize(from: count, count: kinds)
        pcm = .allocate(capacity: samples)
        data.withUnsafeBytes { raw in
            for i in 0..<samples {
                pcm[i] =
                    Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: pcmStart + 2 * i, as: Int16.self)))
                    / 32768
            }
        }
    }

    deinit {
        clips.deallocate()
        pcm.deallocate()
        splits.deallocate()
        lowest.deallocate()
        highest.deallocate()
        counts.deallocate()
    }

    /// Whether the bank holds any recording of `instrument`.
    public func has(_ instrument: SampledInstrument) -> Bool { counts[instrument.rawValue] > 0 }

    /// `pitch` folded by octaves into the instrument's recorded range (each root plays up to five semitones away).
    func fold(_ pitch: Float, _ instrument: SampledInstrument) -> Float {
        let low = lowest[instrument.rawValue] - 5
        let high = highest[instrument.rawValue] + 5
        guard high - low >= 12 else { return pitch }
        var p = pitch
        while p < low { p += 12 }
        while p > high { p -= 12 }
        return p
    }

    /// The clip that plays `instrument` at `pitch` and `velocity`, or -1. A pitched instrument takes the nearest root
    /// in the velocity's layer (the first in file order on a tie); percussion takes take number `round` of that layer
    /// on its drum (a percussion clip's root names its drum: the conga's low tumba below middle C, the conga from it
    /// up), in file order. A layer the instrument lacks falls back to any. Allocation free.
    func lookup(_ instrument: SampledInstrument, pitch: Float, velocity: Float, round: Int) -> Int {
        let kind = instrument.rawValue
        let split = splits[kind]
        let layer = split > 0 && velocity >= split ? 1 : 0
        let drum: Float = instrument == .conga ? (pitch < 60 ? 0 : 1) : 0
        for pass in 0..<2 {
            // Pass 0 insists on the layer; pass 1 takes any.
            if instrument.isPercussion {
                var matching = 0
                for i in 0..<clipCount
                where clips[i].instrument == kind && clips[i].root == drum && (pass == 1 || clips[i].layer == layer) {
                    matching += 1
                }
                guard matching > 0 else { continue }
                let want = ((round % matching) + matching) % matching
                var seen = 0
                for i in 0..<clipCount
                where clips[i].instrument == kind && clips[i].root == drum && (pass == 1 || clips[i].layer == layer) {
                    if seen == want { return i }
                    seen += 1
                }
            } else {
                var best = -1
                var bestScore = Float.greatestFiniteMagnitude
                for i in 0..<clipCount where clips[i].instrument == kind && (pass == 1 || clips[i].layer == layer) {
                    let score = abs(clips[i].root - pitch)
                    if score < bestScore {
                        bestScore = score
                        best = i
                    }
                }
                if best >= 0 { return best }
            }
        }
        return -1
    }
}
