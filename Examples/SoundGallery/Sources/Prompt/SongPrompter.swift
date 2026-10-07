import Foundation
import NardukMusicCore

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Whether the on-device model can write a song here. The gallery shows the prompt controls only when it can; on an
/// older OS, a device without Apple Intelligence, or while the model is not ready, the feature is simply absent.
enum PromptAvailability: Equatable {
    case available
    case unavailable(String)
}

/// The preset prompts the gallery offers.
enum PromptPreset: String, CaseIterable, Identifiable {
    case rainyNight = "Rainy-night lo-fi"
    case sunriseGuitar = "Sunrise with acoustic guitar"
    case warehouse = "Warehouse techno that builds for two minutes"
    case neonDrive = "Neon night drive, synthwave"
    case garage = "Late-night UK garage, rolling"
    case heavyDrop = "A heavy dubstep drop after a long build"

    var id: String { rawValue }
}

/// Turns a prompt into a `SongRecipe` with the on-device language model (`FoundationModels`). Nothing leaves the
/// device: there is no network call and no other model.
enum SongPrompter {
    static var availability: PromptAvailability {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return .available
                case .unavailable(.deviceNotEligible): return .unavailable("This device cannot run Apple Intelligence.")
                case .unavailable(.appleIntelligenceNotEnabled):
                    return .unavailable("Apple Intelligence is turned off.")
                case .unavailable(.modelNotReady): return .unavailable("The on-device model is still getting ready.")
                case .unavailable: return .unavailable("The on-device model is unavailable.")
                }
            }
        #endif
        return .unavailable("Needs iOS 26 or macOS 26 with Apple Intelligence.")
    }

    /// A validated recipe for `prompt`. Throws `PromptError` when the model is unavailable or declines.
    static func recipe(for prompt: String) async throws -> SongRecipe {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return try await OnDeviceRecipeWriter.write(prompt)
            }
        #endif
        throw PromptError.unavailable
    }
}

enum PromptError: LocalizedError {
    case unavailable
    case declined(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The on-device model is not available."
        case .declined(let reason): reason
        }
    }
}

#if canImport(FoundationModels)
    /// The shape the model fills in. Plain strings and small integers, with the allowed words listed as guides, so
    /// a small model has little room to go wrong; `recipe` converts it into a `SongRecipe` and clamps the rest.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable(description: "A song for a music engine to play")
    struct GeneratedSongRecipe {
        @Guide(description: "A short evocative title, at most five words")
        var title: String

        @Guide(description: "One sentence on the mood of the song")
        var mood: String

        @Guide(
            description: "The genre that best fits the request",
            .anyOf([
                "dubstep", "riddim", "drumAndBass", "trap", "house", "chill", "techno", "ukGarage", "synthwave",
                "lofi",
            ]))
        var genre: String

        @Guide(
            description: "The musical mode: minor sounds dark, major bright",
            .anyOf(["minor", "dorian", "phrygian", "harmonicMinor", "major", "lydian", "mixolydian"]))
        var mode: String

        @Guide(description: "Tempo in beats per minute that suits the genre and mood", .range(60...200))
        var bpm: Int

        @Guide(description: "The key's root note, 0 for C, 1 for C sharp, up to 11 for B", .range(0...11))
        var key: Int

        @Guide(
            description: "How chords are voiced",
            .anyOf(["close", "open", "drop2", "spread", "shell", "power"]))
        var voicing: String

        @Guide(
            description: "How chords are played: held, stabs, strum, folk strum or arpeggio",
            .anyOf(["sustain", "stabs", "strum", "folk", "arpeggio"]))
        var comping: String

        @Guide(
            description:
                "The song's plan in order, three to eight parts. Calm songs may use only intro, build and breakdown; "
                + "a song that peaks uses a drop.",
            .count(3...8))
        var parts: [GeneratedPart]

        @Generable
        struct GeneratedPart {
            @Guide(
                description: "What the part does: intro is quiet, build rises, drop is the peak, breakdown is calm",
                .anyOf(["intro", "build", "drop", "breakdown", "drop2"]))
            var section: String

            @Guide(description: "How long the part lasts in seconds", .range(8...60))
            var seconds: Int

            @Guide(description: "How hard the part pushes, 0 gentle to 10 intense", .range(0...10))
            var intensity: Int
        }

        /// The recipe, with an unknown word falling back to the genre's own choice and every number clamped.
        func recipe(seed: UInt64) -> SongRecipe {
            SongRecipe(
                title: title, mood: mood, genre: Genre(rawValue: genre) ?? .house, mode: HarmonyMode(rawValue: mode),
                bpm: Double(bpm), keyPitchClass: key, voicing: ChordVoicing(rawValue: voicing),
                comping: CompingPattern(rawValue: comping),
                parts: parts.map {
                    SongRecipePart(
                        section: SongSection(rawValue: $0.section) ?? .build, seconds: Double($0.seconds),
                        intensity: Double($0.intensity) / 10)
                }, seed: seed
            ).validated()
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    enum OnDeviceRecipeWriter {
        static let instructions = """
            You write songs for a generative music engine. Given a request, choose the genre, mode, tempo, key, chord \
            voicing and comping that fit it, then plan the song as an ordered list of parts. A song that should build \
            for a long time gets one long build part. Use a drop only for songs that peak. Keep the plan between \
            about one and three minutes.
            """

        static func write(_ prompt: String) async throws -> SongRecipe {
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(
                    to: prompt, generating: GeneratedSongRecipe.self, options: GenerationOptions(temperature: 0.9))
                return response.content.recipe(seed: SongSettings.sessionSeed())
            } catch {
                throw PromptError.declined(error.localizedDescription)
            }
        }
    }
#endif
