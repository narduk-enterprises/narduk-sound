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
        "darwin-arm64": 0x79b6_c9b5_a14c_909c,
        "linux-x86_64": 0x330d_8643_585f_3360,
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
        .dubstep: ["darwin-arm64": 0x518a_6bbb_58e6_4717, "linux-x86_64": 0x7368_e9c5_3c8f_61c8],
        .riddim: ["darwin-arm64": 0x4bf2_aafe_24da_7278, "linux-x86_64": 0x9abc_266a_eb45_dbc8],
        .drumAndBass: ["darwin-arm64": 0x3f73_a3a6_8d18_65af, "linux-x86_64": 0x8bb6_79b2_cc40_a854],
        .trap: ["darwin-arm64": 0xb2fc_0671_4bd4_fd74, "linux-x86_64": 0xe1d6_8c8b_40ca_efba],
        .house: ["darwin-arm64": 0x59ad_e41b_a08b_5787, "linux-x86_64": 0x7099_67bc_7023_1612],
        .chill: ["darwin-arm64": 0xed54_7d07_5f21_f47c, "linux-x86_64": 0xabc9_9c4e_23c7_d2cf],
        .techno: ["darwin-arm64": 0xdfb8_8bac_1a48_2563, "linux-x86_64": 0x5740_f242_f1ff_1b52],
        .ukGarage: ["darwin-arm64": 0x012f_7638_eb24_7be7, "linux-x86_64": 0xe989_6941_a15a_231f],
        .synthwave: ["darwin-arm64": 0xcf13_c802_0028_d3bd, "linux-x86_64": 0x39c1_53af_a26b_6088],
        .lofi: ["darwin-arm64": 0x7066_a558_6ba3_d111, "linux-x86_64": 0x06d5_4551_caf9_f7dd],
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
