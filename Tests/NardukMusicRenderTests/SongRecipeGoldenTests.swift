import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// A fixture recipe, played the way the gallery plays one (its settings, its signal script, a queued drop at each
/// drop part), renders to exactly the same samples every time. Per-platform fingerprints, as in `GoldenRenderTests`:
/// when the mapping changes on purpose, read the new fingerprint from the failure, listen to the render, update it.
@Suite struct SongRecipeGoldenTests {
    static let goldens: [String: UInt64] = [
        "darwin-arm64": 0x1246_3953_70ea_d8fb,
        "linux-x86_64": 0x8591_2368_aa6d_9483,
    ]

    static let recipe = SongRecipe(
        title: "Golden Rain", mood: "A short lo-fi build and a drop", genre: .lofi, mode: .dorian, keyPitchClass: 2,
        voicing: .open, comping: .arpeggio,
        parts: [
            SongRecipePart(section: .intro, seconds: 6, intensity: 0.4),
            SongRecipePart(section: .build, seconds: 8, intensity: 0.7),
            SongRecipePart(section: .drop, seconds: 8, intensity: 0.5),
        ], seed: 0x601D)

    static func scenario() -> (MusicScenario, SongSettings) {
        let script = recipe.script()
        let scenario = MusicScenario(
            name: recipe.title, signals: script.signals,
            actions: script.dropTimes.map { MusicScenario.Action(time: $0, queueDrop: true) })
        return (scenario, script.settings)
    }

    @Test func theFixtureRecipeMatchesItsGoldenFingerprint() throws {
        let (scenario, settings) = Self.scenario()
        let audio = OfflineRenderer.render(scenario, seconds: Self.recipe.duration, base: settings)
        #expect(audio.left.allSatisfy(\.isFinite) && audio.right.allSatisfy(\.isFinite))
        #expect(audio.peak > 0.05 && audio.peak <= DSP.ceiling, "peak \(audio.peak)")
        let actual = String(format: "0x%016llx", audio.fingerprint)
        let golden = try #require(
            Self.goldens[GoldenRenderTests.platform], "no golden for \(GoldenRenderTests.platform); actual \(actual)")
        #expect(audio.fingerprint == golden, "\(GoldenRenderTests.platform) fingerprint \(actual)")
    }
}
