import NardukMusicCore
import SwiftUI

/// Prompt-to-song controls: preset prompts, a free-text field, the recipe the model chose and a regenerate button.
/// Renders nothing when the on-device model is unavailable.
struct PromptView: View {
    let model: GalleryModel
    @State private var text = ""
    @State private var lastPrompt = ""
    @State private var recipe: SongRecipe?
    @State private var isWriting = false
    @State private var failure: String?

    var body: some View {
        if SongPrompter.availability == .available {
            VStack(alignment: .leading, spacing: 8) {
                presets
                HStack {
                    TextField("Describe a song", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { write(text) }
                    Button("Write") { write(text) }
                        .disabled(isWriting || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if isWriting { ProgressView("Writing a song on this device…").controlSize(.small) }
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                if let recipe { recipeCard(recipe) }
            }
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(PromptPreset.allCases) { preset in
                    Button(preset.rawValue) {
                        text = preset.rawValue
                        write(preset.rawValue)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isWriting)
                }
            }
        }
    }

    private func recipeCard(_ recipe: SongRecipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(recipe.title).font(.headline)
                Spacer(minLength: 0)
                Button("Regenerate") { write(lastPrompt) }
                    .disabled(isWriting || lastPrompt.isEmpty)
            }
            if !recipe.mood.isEmpty { Text(recipe.mood).font(.footnote).foregroundStyle(.secondary) }
            Text(Self.summary(of: recipe)).font(.footnote.monospaced())
            Text(Self.plan(of: recipe)).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// "techno · phrygian · 132 bpm · key A · power chords, chord stabs".
    static func summary(of recipe: SongRecipe) -> String {
        let settings = recipe.settings()
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        var words = [recipe.genre.shortName.lowercased()]
        if let mode = recipe.mode { words.append(mode.rawValue) }
        words.append("\(Int(settings.bpm.rounded())) bpm")
        words.append("key \(names[recipe.keyPitchClass % 12])")
        if let voicing = recipe.voicing { words.append("\(voicing.rawValue) voicing") }
        if let comping = recipe.comping { words.append(comping.label) }
        return words.joined(separator: " · ")
    }

    /// "intro 20s › build 40s › drop 30s".
    static func plan(of recipe: SongRecipe) -> String {
        recipe.validated().parts.map { "\($0.section.rawValue) \(Int($0.seconds.rounded()))s" }.joined(separator: " › ")
    }

    private func write(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isWriting else { return }
        lastPrompt = prompt
        isWriting = true
        failure = nil
        Task {
            defer { isWriting = false }
            do {
                let written = try await SongPrompter.recipe(for: prompt)
                recipe = written
                model.play(recipe: written)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
