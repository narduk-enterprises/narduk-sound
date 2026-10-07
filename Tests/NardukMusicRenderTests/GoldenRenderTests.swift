import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// The golden render: a fixed seed and a fixed 30 s scenario render to exactly the same samples every time.
///
/// libm's transcendental functions may differ in the last bit between platforms, so each platform has its own
/// golden fingerprint. When the music changes on purpose, run the test, read the new fingerprint from the failure,
/// listen to `narduk-music render --scenario scenarios/build-session.json --out /tmp/x.wav`, and update it here.
@Suite struct GoldenRenderTests {
    static let goldens: [String: UInt64] = [
        // Moved with section variation (#40, 2026-10-07); the Linux value is read from the first Linux CI run.
        "darwin-arm64": 0x7430_00a9_7187_847e,
    ]

    static var platform: String {
        #if os(Linux)
            let os = "linux"
        #elseif canImport(Darwin)
            let os = "darwin"
        #else
            let os = "other"
        #endif
        #if arch(arm64)
            return "\(os)-arm64"
        #elseif arch(x86_64)
            return "\(os)-x86_64"
        #else
            return "\(os)-other"
        #endif
    }

    static func scenario() throws -> MusicScenario {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scenarios/build-session.json")
        return try MusicScenario.load(Data(contentsOf: url))
    }

    @Test func thirtySecondScenarioMatchesItsGoldenFingerprint() throws {
        let audio = OfflineRenderer.render(try Self.scenario(), seconds: 30)
        #expect(audio.frameCount == 30 * 48_000)
        #expect(audio.left.allSatisfy(\.isFinite) && audio.right.allSatisfy(\.isFinite))
        #expect(audio.peak > 0.1 && audio.peak <= DSP.ceiling, "peak \(audio.peak)")
        let actual = String(format: "0x%016llx", audio.fingerprint)
        let golden = try #require(Self.goldens[Self.platform], "no golden for \(Self.platform); actual \(actual)")
        #expect(audio.fingerprint == golden, "\(Self.platform) fingerprint \(actual)")
    }

    /// One golden per genre: the build-session scenario rendered in each genre at its own tempo, so a change to Core
    /// that moves any existing genre's song fails here.
    static let genreGoldens: [Genre: [String: UInt64]] = [
        // Every genre moved with section variation (#40, 2026-10-07); Linux values are read from
        // the first Linux CI run. Goldens pin determinism, not a judgement of how the music sounds.
        .dubstep: ["darwin-arm64": 0xa1c1_e358_a404_14dd],
        .riddim: ["darwin-arm64": 0xd935_4a8e_b788_7d7b],
        .drumAndBass: ["darwin-arm64": 0x04c8_f698_361d_2fe9],
        .trap: ["darwin-arm64": 0x7eaa_4631_d0e4_b6ea],
        .house: ["darwin-arm64": 0x6c3d_fb37_094a_73d9],
        .chill: ["darwin-arm64": 0x5a38_2691_60da_2759],
        .techno: ["darwin-arm64": 0xb790_30ef_5462_0dbb],
        .ukGarage: ["darwin-arm64": 0xd6ff_9ea5_cc59_bf2d],
        .synthwave: ["darwin-arm64": 0xaeec_5a14_1c10_257c],
        .lofi: ["darwin-arm64": 0x4c24_a1e8_c904_a5dd],
        .rock: ["darwin-arm64": 0xb2fc_c28c_9ff1_5d7c],
        .folk: ["darwin-arm64": 0x1e9c_66f6_83fa_1db1],
        .funk: ["darwin-arm64": 0x6f22_24d0_01ce_7450],
        .tropicalHouse: ["darwin-arm64": 0x789a_6df0_c654_bc65],
    ]

    @Test(arguments: Genre.allCases)
    func everyGenreMatchesItsGoldenFingerprint(genre: Genre) throws {
        var scenario = try Self.scenario()
        scenario.genre = genre
        scenario.bpm = genre.defaultBPM
        let audio = OfflineRenderer.render(scenario, seconds: 20)
        #expect(audio.left.allSatisfy(\.isFinite) && audio.right.allSatisfy(\.isFinite))
        #expect(audio.peak > 0.1 && audio.peak <= DSP.ceiling, "\(genre) peak \(audio.peak)")
        let actual = String(format: "0x%016llx", audio.fingerprint)
        let golden = try #require(
            Self.genreGoldens[genre]?[Self.platform], "no \(genre) golden for \(Self.platform); actual \(actual)")
        #expect(audio.fingerprint == golden, "\(genre) \(Self.platform) fingerprint \(actual)")
    }

    @Test func aDifferentSeedWritesADifferentSong() throws {
        var scenario = try Self.scenario()
        let first = OfflineRenderer.render(scenario, seconds: 8)
        scenario.seed = (scenario.seed ?? 0) &+ 1
        let second = OfflineRenderer.render(scenario, seconds: 8)
        #expect(first.fingerprint != second.fingerprint)
        let differing = zip(first.left, second.left).filter { $0 != $1 }.count
        #expect(differing > first.frameCount / 10, "only \(differing) samples differ")
    }

    @Test func theSameSeedRendersTheSameSamples() throws {
        let scenario = try Self.scenario()
        #expect(OfflineRenderer.render(scenario, seconds: 6) == OfflineRenderer.render(scenario, seconds: 6))
    }

    @Test func theScenarioBuildsAndDrops() throws {
        let scenario = try Self.scenario()
        let renderer = OfflineRenderer(settings: scenario.settings())
        renderer.setThresholds(build: scenario.buildThreshold ?? 0.45, drop: scenario.dropThreshold ?? 0.32)
        var signals = scenario.timeline()[...]
        var sections: Set<SongSection> = []
        var legend: Set<String> = []
        for tick in 0..<(30 * 60) {
            let end = Double(tick + 1) / OfflineRenderer.tickRate
            var arrived: [MusicSignal] = []
            while let signal = signals.first, signal.time < end {
                arrived.append(signal)
                signals = signals.dropFirst()
            }
            _ = renderer.advance(signals: arrived)
            sections.insert(renderer.snapshot.section)
            legend.formUnion(renderer.snapshot.legend)
        }
        #expect(sections.contains(.build) && sections.contains { $0 == .drop || $0 == .drop2 }, "\(sections)")
        #expect(legend.contains("laser ← swiftc"), "\(legend.sorted())")
        #expect(renderer.snapshot.levelLabel?.hasPrefix("CPU ") == true)
    }

    @Test func wavHasAHeaderAndEveryFrame() throws {
        let audio = OfflineRenderer.render(try Self.scenario(), seconds: 1)
        let wav = AudioFileWriter.wavData(audio)
        #expect(wav.count == 44 + audio.frameCount * 4)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    }

    @Test func segmentsRampTheLevelAndTakeCuesInTurn() {
        let scenario = MusicScenario(segments: [
            .init(
                from: 0, to: 1, every: 0.25, level: [0, 0.6], levelLabel: "heat",
                cues: [.spark("a"), .voice("b")], cueEvery: 2)
        ])
        let timeline = scenario.timeline()
        #expect(timeline.map(\.time) == [0, 0.25, 0.5, 0.75])
        #expect(timeline.map { (($0.level ?? -1) * 10).rounded() } == [0, 2, 4, 6])
        #expect(timeline.map(\.levelLabel) == ["heat 0%", "heat 20%", "heat 40%", "heat 60%"])
        #expect(timeline.map { $0.cues.map(\.label) } == [["a"], [], ["b"], []])
    }
}
