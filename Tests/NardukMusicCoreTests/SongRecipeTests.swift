import Foundation
import Testing

@testable import NardukMusicCore

@Suite struct SongRecipeTests {
    static let sample = SongRecipe(
        title: "Warehouse Build", mood: "Techno that builds for two minutes", genre: .techno, mode: .phrygian,
        bpm: 132, keyPitchClass: 9, voicing: .power, comping: .stabs,
        parts: [
            SongRecipePart(section: .intro, seconds: 20, intensity: 0.3),
            SongRecipePart(section: .build, seconds: 40, intensity: 0.8),
            SongRecipePart(section: .drop, seconds: 30, intensity: 0.6),
            SongRecipePart(section: .breakdown, seconds: 10, intensity: 0.5),
            SongRecipePart(section: .drop2, seconds: 20, intensity: 1),
        ], seed: 7)

    @Test func theSettingsFollowTheRecipe() {
        let settings = Self.sample.settings()
        #expect(settings.genre == .techno && settings.bpm == 132 && settings.keyRoot == 69 && settings.seed == 7)
        #expect(settings.mode == .phrygian && settings.voicing == .power && settings.comping == .stabs)
    }

    @Test func aMissingTempoTakesTheGenresOwn() {
        var recipe = Self.sample
        recipe.bpm = nil
        #expect(recipe.settings().bpm == Genre.techno.defaultBPM)
    }

    @Test(arguments: Genre.allCases) func everyGenreMapsToAPlayableRecipe(genre: Genre) {
        let recipe = SongRecipe(title: "", genre: genre)
        let settings = recipe.settings()
        #expect(settings.genre == genre && settings.family == genre.family)
        #expect(SongRecipe.tempoRange.contains(settings.bpm))
        let script = recipe.script()
        #expect(!script.signals.isEmpty && script.seconds == recipe.duration)
    }

    @Test func everyEnumCaseTheModelCanEmitMaps() {
        for mode in HarmonyMode.allCases {
            for voicing in ChordVoicing.allCases {
                for comping in CompingPattern.allCases {
                    let settings = SongRecipe(title: "x", genre: .house, mode: mode, voicing: voicing, comping: comping)
                        .settings()
                    #expect(settings.mode == mode && settings.voicing == voicing && settings.comping == comping)
                }
            }
        }
        for section in SongSection.allCases {
            let range = SongRecipe.level(of: section)
            #expect(range.lowerBound >= 0 && range.upperBound <= 1)
        }
    }

    @Test func validationClampsWhatTheModelGetsWrong() {
        let wild = SongRecipe(
            title: "  \n ", mood: String(repeating: "m", count: 400), genre: .dubstep, bpm: .infinity,
            keyPitchClass: -3,
            parts: (0..<40).map { wildPart($0) })
        let recipe = wild.validated()
        #expect(recipe.title == "Dubstep" && recipe.mood.count == 160)
        #expect(recipe.bpm == nil && recipe.keyPitchClass == 9)
        #expect(recipe.parts.count == SongRecipe.maxParts)
        #expect(recipe.parts.allSatisfy { SongRecipe.partSecondsRange.contains($0.seconds) })
        #expect(recipe.parts.allSatisfy { (0...1).contains($0.intensity) })
        #expect(recipe.validated() == recipe)
        var tooFast = Self.sample
        tooFast.bpm = 900
        #expect(tooFast.validated().bpm == SongRecipe.tempoRange.upperBound)
    }

    @Test func energyBuildsThroughABuildAndSettlesInABreakdown() {
        let recipe = Self.sample
        let start = recipe.energy(at: 0)
        let buildStart = recipe.energy(at: 20)
        let buildEnd = recipe.energy(at: 59)
        let drop = recipe.energy(at: 75)
        let breakdown = recipe.energy(at: 95)
        #expect(start < 0.31 && buildStart < buildEnd && buildEnd > 0.7)
        #expect(drop >= 0.8 && breakdown < 0.4)
        #expect(recipe.energy(at: 10_000) == SongRecipe.target(of: recipe.parts.last!))
        for time in stride(from: 0.0, to: recipe.duration, by: 0.5) {
            #expect((0...1).contains(recipe.energy(at: time)))
        }
    }

    @Test func theScriptCarriesTheCurveAndQueuesTheDrops() {
        let script = Self.sample.script()
        #expect(script.dropTimes == [60, 100])
        #expect(script.seconds == 120)
        #expect(script.signals.count == 480)
        #expect(script.signals.allSatisfy { $0.level != nil && $0.character != nil })
        #expect(zip(script.signals, script.signals.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(script.signals.first?.levelLabel == "Warehouse Build intro")
    }

    @Test func theMappingIsDeterministic() {
        #expect(Self.sample.script() == Self.sample.script())
        #expect(Self.sample.script(interval: 0).signals.count == 480)
    }

    @Test func aRecipeSurvivesJSON() throws {
        let data = try JSONEncoder().encode(Self.sample)
        #expect(try JSONDecoder().decode(SongRecipe.self, from: data) == Self.sample)
    }
}

private func wildPart(_ index: Int) -> SongRecipePart {
    SongRecipePart(
        section: SongSection.allCases[index % SongSection.allCases.count],
        seconds: index.isMultiple(of: 2) ? .nan : 1_000, intensity: index.isMultiple(of: 3) ? 9 : -2)
}
