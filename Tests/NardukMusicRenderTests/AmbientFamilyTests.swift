import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// The ambient family end to end: a scenario's signal level in, swells and settles out. Set
/// `NARDUK_AMBIENT_DEMO_DIR` to also write the render as `ambient-family-demo.wav`.
@Suite struct AmbientFamilyTests {
    /// Fingerprints per platform. A 150 s render runs the hall's feedback loops long enough for a last-bit libm
    /// difference to show, so darwin accepts the value both a developer Mac (macOS 27) and the CI runner produce.
    static let goldens: [String: Set<UInt64>] = [
        "darwin-arm64": [0x1fd9_a80d_a1c2_716d, 0x6dad_7bc9_c2a3_30da],
        "linux-x86_64": [0x010e_8b77_6615_be55],
    ]

    static func scenario() throws -> MusicScenario {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scenarios/ambient-swell.json")
        return try MusicScenario.load(Data(contentsOf: url))
    }

    /// Renders the scenario tick by tick, keeping what the conductor reported along the way.
    struct Run {
        var audio: RenderedAudio
        var sections: [SongSection] = []
        var legend: Set<String> = []
        var hits: Set<Instrument> = []
    }

    static func run(_ scenario: MusicScenario, seconds: Double) -> Run {
        let renderer = OfflineRenderer(settings: scenario.settings())
        renderer.setThresholds(build: scenario.buildThreshold ?? 0.45, drop: scenario.dropThreshold ?? 0.32)
        var signals = scenario.timeline()[...]
        var left: [Float] = []
        var right: [Float] = []
        var result = (sections: [SongSection](), legend: Set<String>(), hits: Set<Instrument>())
        for tick in 0..<Int(seconds * OfflineRenderer.tickRate) {
            let end = Double(tick + 1) / OfflineRenderer.tickRate
            var arrived: [MusicSignal] = []
            while let signal = signals.first, signal.time < end {
                arrived.append(signal)
                signals = signals.dropFirst()
            }
            let block = renderer.advance(signals: arrived)
            left += block.left
            right += block.right
            if result.sections.last != renderer.snapshot.section { result.sections.append(renderer.snapshot.section) }
            result.legend.formUnion(renderer.snapshot.legend)
            result.hits.formUnion(renderer.takeHits())
        }
        return Run(
            audio: RenderedAudio(sampleRate: 48_000, left: left, right: right), sections: result.sections,
            legend: result.legend, hits: result.hits)
    }

    /// One 150 s render shared by the tests that only read it (a debug build takes a minute over it).
    static let song: Run = run((try? scenario()) ?? MusicScenario(), seconds: 150)

    static func rms(_ audio: RenderedAudio, from: Double, to: Double) -> Float {
        let range = Int(from * audio.sampleRate)..<Int(to * audio.sampleRate)
        var sum: Float = 0
        for n in range { sum += audio.left[n] * audio.left[n] }
        return (sum / Float(range.count)).squareRoot()
    }

    @Test func sectionsAreNamedByHowTheMusicMoves() {
        #expect(
            SongSection.allCases.map { $0.label(in: .ambient) } == [
                "stillness", "swell", "bloom", "settle", "radiance",
            ])
        #expect(SongSection.allCases.map { $0.label(in: .electronic) } == SongSection.allCases.map(\.rawValue))
    }

    @Test func anAmbientSongHasNoDrumsAndLongSwells() throws {
        let run = Self.song
        #expect(run.audio.left.allSatisfy(\.isFinite) && run.audio.right.allSatisfy(\.isFinite))
        #expect(run.audio.peak > 0.05 && run.audio.peak <= DSP.ceiling, "peak \(run.audio.peak)")
        let drums: Set<Instrument> = [.kick, .snare, .hat, .openHat, .riser, .impact, .tapeStop, .wobble, .glitch]
        #expect(run.hits.isDisjoint(with: drums), "drums in an ambient song: \(run.hits.intersection(drums))")
        #expect(run.hits.contains(.keys))
        #expect(run.sections.contains(.intro) && run.sections.contains(.build), "\(run.sections)")
        #expect(run.sections.contains { $0 == .drop || $0 == .drop2 }, "\(run.sections)")
        #expect(run.legend.contains { $0.hasPrefix("ambient · ") }, "\(run.legend.sorted())")
    }

    @Test func theMusicSwellsAndSettlesWithTheSignalLevel() throws {
        let run = Self.song
        let quiet = Self.rms(run.audio, from: 4, to: 24)
        let loud = Self.rms(run.audio, from: 76, to: 96)
        #expect(loud > quiet * 1.4, "swell: quiet \(quiet), loud \(loud)")
        // After the signal fades the pads and their long tails keep ringing, softer.
        let settled = Self.rms(run.audio, from: 138, to: 150)
        #expect(settled < loud * 0.8 && settled > 0, "settle: loud \(loud), settled \(settled)")
    }

    @Test func anAmbientRenderIsDeterministic() throws {
        let scenario = try Self.scenario()
        #expect(Self.run(scenario, seconds: 20).audio == Self.run(scenario, seconds: 20).audio)
    }

    @Test func theFamilyIsTheOnlyThingThatChangesAnElectronicSong() throws {
        var scenario = try Self.scenario()
        scenario.family = nil
        let electronic = Self.run(scenario, seconds: 20)
        scenario.family = .electronic
        #expect(electronic.audio == Self.run(scenario, seconds: 20).audio)
        scenario.family = .ambient
        #expect(electronic.audio != Self.run(scenario, seconds: 20).audio)
    }

    @Test func theAmbientRenderMatchesItsGoldenFingerprint() throws {
        let run = Self.song
        let actual = String(format: "0x%016llx", run.audio.fingerprint)
        let golden = try #require(Self.goldens[GoldenRenderTests.platform])
        #expect(golden.contains(run.audio.fingerprint), "\(GoldenRenderTests.platform) fingerprint \(actual)")
        if let directory = ProcessInfo.processInfo.environment["NARDUK_AMBIENT_DEMO_DIR"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("ambient-family-demo.wav")
            try AudioFileWriter.wavData(run.audio).write(to: url)
        }
    }
}
