import Foundation
import NardukMusicCore

/// The recorded voice behind `Instrument.vocalSample` (narduk-libs#1641): looped vowel sustains, syllable chops and
/// sung scale runs of one female singer from VocalSet (CC BY 4.0, see `Resources/LICENSES/VocalSet.md`), decoded once
/// into Float. Immutable after loading, so render-thread voices read it without a lock and without allocating.
public final class SampleBank: @unchecked Sendable {
    /// One recording. `offset`/`count` locate it in `pcm`; a sustain loops `loopStart ..< loopEnd` (the crossfade that
    /// makes the loop seamless is baked into its last samples); `root` is the MIDI pitch it was sung at.
    public struct Clip: Sendable {
        public var kind: SampleKind
        public var vowel: Int
        public var technique: SampleTechnique
        public var root: Float
        public var offset: Int
        public var count: Int
        public var loopStart: Int
        public var loopEnd: Int
        public var index: Int
    }

    public let sampleRate: Double
    public let clipCount: Int
    let clips: UnsafeMutablePointer<Clip>
    let pcm: UnsafeMutablePointer<Float>
    public let totalSamples: Int

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            var kind: String
            var vowel: String
            var technique: String
            var root: Double
            var offset: Int
            var count: Int
            var loopStart: Int
            var loopEnd: Int
            var index: Int
        }
        var sampleRate: Double
        var clips: [Entry]
    }

    /// The shipped set, loaded on first use (a synth core touches it when it is built, so the audio thread never does).
    /// `nil` if the resource is missing or damaged: `vocalSample` notes are then silent.
    public static let shared: SampleBank? = {
        guard
            let url = Bundle.module.url(forResource: "vocalsamples", withExtension: "bin", subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "vocalsamples", withExtension: "bin"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return SampleBank(data: data)
    }()

    /// Parses `NVS1` + little-endian manifest length + JSON manifest + 16-bit PCM.
    public init?(data: Data) {
        guard data.count > 8, data.prefix(4) == Data("NVS1".utf8) else { return nil }
        let manifestLength = data.subdata(in: 4..<8).withUnsafeBytes {
            Int($0.loadUnaligned(as: UInt32.self).littleEndian)
        }
        guard 8 + manifestLength <= data.count,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data.subdata(in: 8..<(8 + manifestLength)))
        else { return nil }
        let pcmStart = 8 + manifestLength
        let samples = (data.count - pcmStart) / 2
        var entries: [Clip] = []
        for e in manifest.clips {
            guard let kind = SampleKind(rawValue: e.kind), let technique = SampleTechnique(rawValue: e.technique),
                let vowel = VocalVowel(rawValue: e.vowel), e.offset >= 0, e.count > 4, e.offset + e.count <= samples,
                e.loopStart >= 0, e.loopEnd <= e.count, kind != .sustain || e.loopEnd > e.loopStart + 8
            else { return nil }
            entries.append(
                Clip(
                    kind: kind, vowel: vowel.index, technique: technique, root: Float(e.root), offset: e.offset,
                    count: e.count, loopStart: e.loopStart, loopEnd: e.loopEnd, index: e.index))
        }
        guard !entries.isEmpty, manifest.sampleRate > 8_000 else { return nil }
        sampleRate = manifest.sampleRate
        clipCount = entries.count
        totalSamples = samples
        clips = .allocate(capacity: entries.count)
        clips.initialize(from: entries, count: entries.count)
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
    }

    /// The clip that plays `kind` in `vowel` and `technique` at `pitch`, and how many of its kind there are. A
    /// sustain is the nearest root; a chop is slice number `slice` (0 ... 1 across the set); a run is the one in this
    /// vowel (or the first). A technique the set lacks falls back to a neighbour. Allocation free.
    func lookup(kind: SampleKind, vowel: Int, technique: SampleTechnique, pitch: Float, slice: Float) -> Int {
        let v = vowel == 5 ? 2 : vowel  // "mm" sings as "oo"
        var best = -1
        var bestScore = Float.greatestFiniteMagnitude
        var matching = 0
        for pass in 0..<2 {
            // Pass 0 insists on the technique; pass 1 takes any.
            for i in 0..<clipCount where clips[i].kind == kind {
                let c = clips[i]
                if kind != .chop && c.vowel != v { continue }
                if pass == 0 && c.technique != technique { continue }
                switch kind {
                case .sustain:
                    let score = abs(c.root - pitch)
                    if score < bestScore {
                        bestScore = score
                        best = i
                    }
                case .run:
                    if best < 0 || (c.technique == technique && clips[best].technique != technique) { best = i }
                case .chop:
                    matching += 1
                }
            }
            if kind == .chop && matching > 0 {
                // The slice-th matching chop, in file order.
                let want = min(Int(max(min(slice, 0.999), 0) * Float(matching)), matching - 1)
                var seen = 0
                for i in 0..<clipCount where clips[i].kind == .chop && (pass == 1 || clips[i].technique == technique) {
                    if seen == want { return i }
                    seen += 1
                }
            }
            if best >= 0 { return best }
        }
        return best
    }
}
