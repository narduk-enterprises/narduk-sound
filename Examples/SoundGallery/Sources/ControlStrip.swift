import NardukSoundVisuals
import SwiftUI

extension GalleryModel {
    /// The play button's title: Play, Pause or Resume (or Choose file…) for the current source and state.
    var transportTitle: String {
        if isRunning { return isPaused ? "Resume" : "Pause" }
        return input == .file ? "Choose file…" : "Play"
    }

    var transportIcon: String { isRunning && !isPaused ? "pause.fill" : "play.fill" }

    /// Pauses or resumes while a source runs; otherwise starts it, or asks for a file first.
    func togglePlayback(chooseFile: () -> Void) {
        if isRunning {
            togglePause()
        } else if input == .file {
            chooseFile()
        } else {
            Task { await start() }
        }
    }
}

/// The one set of transport controls: Play / Pause / Resume (the space bar, when `spaceShortcut`) and Stop. The strip
/// shows it large; the iPhone's header shows it `compact`, icon only, with the strip's own copy hidden.
struct TransportControls: View {
    @Bindable var model: GalleryModel
    @Binding var importing: Bool
    var compact = false
    var spaceShortcut = false

    var body: some View {
        if compact {
            HStack(spacing: GalleryTheme.Space.s) {
                playButton.labelStyle(.iconOnly)
                if model.isRunning { stopButton.labelStyle(.iconOnly) }
            }
        } else {
            HStack(spacing: GalleryTheme.Space.s) {
                playButton.frame(maxWidth: .infinity)
                if model.isRunning { stopButton }
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder private var playButton: some View {
        let button = Button {
            model.togglePlayback { importing = true }
        } label: {
            Label(model.transportTitle, systemImage: model.transportIcon)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRunning ? .gray : GalleryPalette.low)
        if spaceShortcut { button.keyboardShortcut(.space, modifiers: []) } else { button }
    }

    private var stopButton: some View {
        Button {
            model.stop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
    }
}

/// Every control in one strip: the source, the demo song and its prompt, and the transport. It is the sidebar on a Mac
/// or iPad, a sheet on an iPhone and the full-screen overlay's panel. The palette controls (`PaletteControls`) are its "Look" section.
struct ControlStrip: View {
    @Bindable var model: GalleryModel
    @Binding var importing: Bool
    /// The drop-in `.metal` visualizers (narduk-libs#1665), for the folder row.
    var plugins: IntensePluginLibrary?
    /// False on an iPhone, where the header carries the transport and the sheet must not repeat it.
    var showsTransport = true
    /// Binds the space bar to play and pause. Off in the full-screen overlay, where the stage handles the key itself.
    var spaceShortcut = true

    var body: some View {
        VStack(alignment: .leading, spacing: GalleryTheme.Space.l) {
            if showsTransport { transport }
            section("Source") {
                Picker("Source", selection: $model.input) {
                    ForEach(GalleryInput.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isRunning)
            }
            if model.input == .demo { section("Song") { songControls } }
            section("Look") { PaletteControls(model: model) }
            if model.input == .demo { section("Describe a song") { PromptView(model: model) } }
            if let plugins { section("Plugins") { pluginFolderRow(plugins) } }
        }
        .padding(GalleryTheme.Space.m)
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: GalleryTheme.Space.s) {
            TransportControls(model: model, importing: $importing, spaceShortcut: spaceShortcut)
            Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
        }
    }

    /// Where a `.metal` visualizer is dropped, with the count of what loaded.
    private func pluginFolderRow(_ plugins: IntensePluginLibrary) -> some View {
        HStack(spacing: GalleryTheme.Space.s) {
            Image(systemName: "puzzlepiece.extension")
            Text("\(plugins.entries.count) in \(plugins.directory.path)").lineLimit(1).truncationMode(.middle)
            #if os(macOS)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([plugins.directory]) }
            #endif
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: GalleryTheme.Space.s) {
            Text(title).font(GalleryTheme.sectionTitle).foregroundStyle(.secondary)
            content()
        }
    }

    /// The demo song's style (every genre, the guitars, the ambient family) and a new seed.
    private var songControls: some View {
        HStack {
            Picker("Song", selection: $model.song.style) {
                ForEach(GallerySongStyle.all) { style in
                    Text(style.title).tag(style)
                }
                if case .recipe = model.song.style {
                    Text(model.song.style.title).tag(model.song.style)
                }
            }
            .labelsHidden()
            .disabled(model.isRunning)
            Button("New song") { model.newSong() }
                .disabled(model.isRunning || model.song.style == .demo)
            Spacer(minLength: 0)
        }
    }
}
