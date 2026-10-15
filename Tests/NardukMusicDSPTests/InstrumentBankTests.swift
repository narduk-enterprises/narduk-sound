import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The recorded instruments (`InstrumentBank`, `InstrumentVoice`) and the core's fixed pool that plays them.
struct InstrumentBankTests {
    static let bank = InstrumentBank.shared

    @Test func theShippedBankHoldsEveryInstrument() throws {
        let bank = try #require(Self.bank, "Resources/instruments.bin did not load")
        #expect(bank.sampleRate == 32_000)
        for instrument in SampledInstrument.allCases {
            #expect(bank.has(instrument), "\(instrument) missing")
        }
        for i in 0..<bank.clipCount {
            let c = bank.clips[i]
            #expect(c.offset + c.count <= bank.totalSamples)
            #expect(c.loopEnd == 0 || (c.loopStart + 8 < c.loopEnd && c.loopEnd <= c.count))
        }
        // The loops are on the held instruments only.
        for i in 0..<bank.clipCount where bank.clips[i].loopEnd > 0 {
            let kind = SampledInstrument(rawValue: bank.clips[i].instrument)
            #expect(kind?.sustains == true, "\(String(describing: kind)) loops")
        }
    }

    /// The CC BY piano has its attribution where an app can show it.
    @Test func theCreditsNameThePiano() {
        #expect(
            InstrumentBank.credits.contains {
                $0.contains("Salamander Grand Piano") && $0.contains("Alexander Holm") && $0.contains("CC BY 3.0")
            })
        #expect(InstrumentBank.credits.count == 6)
    }

    @Test func aDamagedBankIsRefused() {
        #expect(InstrumentBank(data: Data()) == nil)
        #expect(InstrumentBank(data: Data("NVS1xxxxyyyy".utf8)) == nil)
        var bytes = Data("NVS2".utf8)
        let manifest = Data(
            #"{"sampleRate":32000,"instruments":[],"clips":[{"instrument":"piano","root":60,"layer":0,"offset":0,"count":100,"loopStart":0,"loopEnd":0,"index":0}]}"#
                .utf8)
        withUnsafeBytes(of: UInt32(manifest.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(manifest)
        // The clip claims 100 samples; the body holds 10.
        bytes.append(Data(count: 20))
        #expect(InstrumentBank(data: bytes) == nil)
        bytes.append(Data(count: 180))
        #expect(InstrumentBank(data: bytes)?.has(.piano) == true)
    }

    @Test func aPitchedNoteTakesTheNearestRootWithinAFifth() throws {
        let bank = try #require(Self.bank)
        for instrument in SampledInstrument.allCases where !instrument.isPercussion {
            for pitch in stride(from: Float(24), through: 108, by: 1) {
                let folded = bank.fold(pitch, instrument)
                #expect(Int(folded - pitch) % 12 == 0)
                let clip = bank.lookup(instrument, pitch: folded, velocity: 0.7, round: 0)
                #expect(clip >= 0)
                let c = bank.clips[clip]
                #expect(c.instrument == instrument.rawValue)
                // Roots sit a minor third apart, so no note is pitched more than a fifth (in practice two semitones).
                #expect(abs(c.root - folded) <= 5, "\(instrument) at \(pitch): root \(c.root)")
            }
        }
    }

    @Test func velocityPicksTheLayer() throws {
        let bank = try #require(Self.bank)
        let soft = bank.lookup(.sax, pitch: 63, velocity: 0.3, round: 0)
        let loud = bank.lookup(.sax, pitch: 63, velocity: 0.9, round: 0)
        #expect(bank.clips[soft].layer == 0 && bank.clips[loud].layer == 1)
        let shake = bank.lookup(.tambourine, pitch: 60, velocity: 0.2, round: 0)
        let hit = bank.lookup(.tambourine, pitch: 60, velocity: 0.8, round: 0)
        #expect(bank.clips[shake].layer == 0 && bank.clips[hit].layer == 1)
    }

    @Test func percussionTakesTurnsAndCongasPickTheirDrum() throws {
        let bank = try #require(Self.bank)
        let takes = Set((0..<8).map { bank.lookup(.shaker, pitch: 60, velocity: 0.1, round: $0) })
        #expect(takes.count > 1, "the shaker repeats one take")
        #expect(takes.allSatisfy { $0 >= 0 && bank.clips[$0].instrument == SampledInstrument.shaker.rawValue })
        let low = bank.lookup(.conga, pitch: 55, velocity: 0.5, round: 0)
        let high = bank.lookup(.conga, pitch: 64, velocity: 0.5, round: 0)
        #expect(bank.clips[low].root == 0 && bank.clips[high].root == 1)
    }

    /// Every instrument, soft and loud, at the bottom, middle and top of its range: finite, bounded, no click on and
    /// silence once it ends.
    @Test(arguments: SampledInstrument.allCases)
    func everyInstrumentIsCleanAndEnds(instrument: SampledInstrument) throws {
        let bank = try #require(Self.bank)
        let engineRate: Float = 48_000
        for pitch: Float in [48, 66, 84] {
            for velocity: Float in [0.3, 1] {
                let folded = instrument.isPercussion ? pitch : bank.fold(pitch, instrument)
                let clip = bank.lookup(instrument, pitch: folded, velocity: velocity, round: Int(pitch))
                let shift = instrument.isPercussion ? 0 : Double(min(max(folded - bank.clips[clip].root, -7), 7))
                var voice = InstrumentVoice()
                voice.trigger(
                    instrument, bank: bank, clip: clip, rate: pow(2, shift / 12) * bank.sampleRate / 48_000,
                    gateSamples: 24_000, velocity: velocity, pan: 0, engineRate: engineRate)
                var peak: Float = 0
                var first: Float = 0
                var last: Float = 1
                var samples = 0
                while voice.active, samples < 48_000 * 6 {
                    let (l, r) = voice.next()
                    #expect(l.isFinite && r.isFinite)
                    if samples == 0 { first = max(abs(l), abs(r)) }
                    peak = max(peak, abs(l), abs(r))
                    last = max(abs(l), abs(r))
                    samples += 1
                }
                #expect(!voice.active, "\(instrument) at \(pitch) never ended")
                #expect(peak > 0.005 && peak < 1, "\(instrument) at \(pitch), \(velocity): peak \(peak)")
                #expect(first < 0.05, "\(instrument) clicks on: \(first)")
                #expect(last < 0.01, "\(instrument) at \(pitch) clicks off: \(last)")
            }
        }
    }

    @Test func aSoftNoteIsSofterThanALoudOne() throws {
        let bank = try #require(Self.bank)
        func peak(_ velocity: Float) -> Float {
            var voice = InstrumentVoice()
            let clip = bank.lookup(.piano, pitch: 60, velocity: velocity, round: 0)
            voice.trigger(
                .piano, bank: bank, clip: clip, rate: bank.sampleRate / 48_000, gateSamples: 4_800,
                velocity: velocity, pan: 0, engineRate: 48_000)
            var p: Float = 0
            while voice.active { p = max(p, abs(voice.next().0)) }
            return p
        }
        // No gain floor: a quarter-velocity note is well under half as loud.
        #expect(peak(0.25) < 0.4 * peak(1))
    }

    @Test func aStolenNoteFadesInsteadOfStopping() throws {
        let bank = try #require(Self.bank)
        var voice = InstrumentVoice()
        voice.trigger(
            .flute, bank: bank, clip: bank.lookup(.flute, pitch: 72, velocity: 1, round: 0),
            rate: bank.sampleRate / 48_000, gateSamples: 48_000, velocity: 1, pan: 0, engineRate: 48_000)
        var level: Float = 0
        for _ in 0..<4_800 { level = max(level, abs(voice.next().0)) }
        voice.steal(engineRate: 48_000)
        var samples = 0
        var jump: Float = 0
        var previous = voice.next().0
        while voice.active {
            let s = voice.next().0
            jump = max(jump, abs(s - previous))
            previous = s
            samples += 1
        }
        #expect(samples > 200 && samples <= 241, "fade took \(samples) samples")
        #expect(abs(previous) < 0.01)
    }

    /// Seventeen piano notes at once into a sixteen-voice pool, through the whole core: the oldest is stolen and faded
    /// in the tail slot, the output stays finite and bounded, and every note has finished a few seconds later.
    @Test func thePoolStealsTheOldestNote() {
        let core = DropSynthCore(sampleRate: 48_000, bpm: 120)
        for i in 0..<20 {
            core.schedule(
                ScheduledNote(
                    step: i % 2, instrument: .keys, velocity: 0.8,
                    params: NoteParams(pitch: 48 + i * 2, lengthSteps: 8, voice: KeysVoice.sampledPiano)))
        }
        let frames = 48_000 * 5
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        core.render(frames: frames, left: left, right: right)
        var peak: Float = 0
        for i in 0..<frames {
            #expect(left[i].isFinite && right[i].isFinite)
            peak = max(peak, abs(left[i]), abs(right[i]))
        }
        #expect(peak > 0.01 && peak <= DSP.ceiling)
        #expect(core.takeHits().contains(.keys))
    }

    /// Without the bank, each sampled voice plays its synth stand-in instead of going silent, and the hand percussion
    /// plays the synth drums.
    @Test(arguments: [
        KeysVoice.sampledPiano, KeysVoice.sampledSteelDrum, KeysVoice.sampledFlute, KeysVoice.sampledSax,
        KeysVoice.sampledNylonGuitar, KeysVoice.sampledConga,
    ])
    func aMissingBankFallsBackToTheSynth(voice: Int) {
        for bank in [InstrumentBank.shared, nil] {
            let core = DropSynthCore(sampleRate: 48_000, bpm: 120, stepsPerBar: 16, instrumentBank: bank)
            core.schedule(
                ScheduledNote(
                    step: 0, instrument: .keys, velocity: 0.8,
                    params: NoteParams(pitch: 64, lengthSteps: 4, voice: voice)))
            core.schedule(
                ScheduledNote(
                    step: 0, instrument: .hat, velocity: 0.8, params: NoteParams(voice: PercussionVoice.shaker)))
            let frames = 24_000
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer {
                left.deallocate()
                right.deallocate()
            }
            core.render(frames: frames, left: left, right: right)
            var peak: Float = 0
            for i in 0..<frames { peak = max(peak, abs(left[i]), abs(right[i])) }
            #expect(peak > 0.01, "voice \(voice) silent with bank \(bank == nil ? "missing" : "loaded")")
        }
    }
}
