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
        "darwin-arm64": 0x5c55_d69a_5457_68c9
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
        .dubstep: ["darwin-arm64": 0x186e_89cd_9779_0060],
        .riddim: ["darwin-arm64": 0xbb32_056b_bc1f_5273],
        .drumAndBass: ["darwin-arm64": 0xad85_2179_1429_1eb4],
        .trap: ["darwin-arm64": 0x7a9f_d9ca_f7aa_e08c],
        .house: ["darwin-arm64": 0x4bb8_7609_f5fe_c25c],
        .chill: ["darwin-arm64": 0x98c1_6fce_ca4e_cbe4],
        .techno: ["darwin-arm64": 0x8185_b361_eccd_fc28],
        .ukGarage: ["darwin-arm64": 0xe9b9_f81b_e7c8_fa50],
        .synthwave: ["darwin-arm64": 0x38e0_250e_e45d_9e56],
        .lofi: ["darwin-arm64": 0x1c8a_0fe2_bc4e_6fe9],
        .rock: ["darwin-arm64": 0x7ffd_5113_454d_0e66],
        .folk: ["darwin-arm64": 0x36fb_8ebc_f56c_eb71],
        .funk: ["darwin-arm64": 0x150e_33ad_5c31_abd4],
        // Tropical house moved again with its recorded instruments and call-and-answer drop (narduk-sound#34).
        .tropicalHouse: ["darwin-arm64": 0xd5da_42c4_ba8a_0735],
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
