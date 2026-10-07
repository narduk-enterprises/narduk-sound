import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#endif

struct GalleryView: View {
    @Bindable var model: GalleryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var pickedFile: URL?
    /// The tile shown alone, edge to edge; nil shows the grid.
    @State private var fullscreenID: String?
    @State private var overlayVisible = true
    @State private var controlsOpen = false
    @State private var overlayTick = 0
    @FocusState private var stageFocused: Bool

    private let tiles = GalleryTile.all

    /// The render budget: 60 fps while the app is on screen and playing, nothing otherwise.
    private var isDrawing: Bool {
        scenePhase == .active && ((model.isRunning && !model.isPaused) || model.repaintHold)
    }

    var body: some View {
        Group {
            if let id = fullscreenID, let index = tiles.firstIndex(where: { $0.id == id }) {
                stage(at: index)
            } else {
                grid
            }
        }
        .background(GalleryPalette.background)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                pickedFile = url
                Task { await model.start(file: url) }
            }
        }
        .task {
            // `-autoplay demo|microphone` or `-autofile <path>` starts a source at launch, for smoke runs and screenshots;
            // `-song <style id>` (genre-techno, guitars, ...) picks the demo song and `-fullscreen <tile id>` opens a tile.
            let defaults = UserDefaults.standard
            if let styleID = defaults.string(forKey: "song"),
                let style = GallerySongStyle.all.first(where: { $0.id == styleID })
            {
                model.song.style = style
            }
            // `-palette random|<preset id>` and `-hue <degrees>` set the palette at launch, for screenshots.
            if let name = defaults.string(forKey: "palette") {
                if name == "random" {
                    model.rollRandom(seed: UInt64(defaults.integer(forKey: "paletteSeed")))
                } else if let preset = SoundPalettePreset(rawValue: name) {
                    model.choose(preset)
                }
            }
            if defaults.object(forKey: "hue") != nil { model.look.hueShift = Float(defaults.double(forKey: "hue")) }
            if let tileID = defaults.string(forKey: "fullscreen") { open(tileID) }
            if let path = defaults.string(forKey: "autofile") {
                model.input = .file
                await model.start(file: URL(fileURLWithPath: path))
            } else if let raw = defaults.string(forKey: "autoplay"),
                let input = GalleryInput.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                ),
                input != .file
            {
                model.input = input
                await model.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
        }
        .onChange(of: fullscreenID) { old, new in
            setWindowFullScreen(new != nil)
            if old == nil, new != nil { wakeOverlay() }
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 0) {
            controls
            // One timeline polls one frame per tick for every card; a card polling for itself would run the analyzer
            // (and its smoothing) once per card.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isDrawing)) { timeline in
                let context = TileContext(
                    model: model, frame: model.poll(at: timeline.date),
                    framesPerSecond: isDrawing ? SoundRenderBudget.normal : 0,
                    tick: timeline.date.timeIntervalSinceReferenceDate)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(tiles) { tile in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tile.id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                tile.content(context)
                                    .frame(height: tile.gridHeight)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .padding(10)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { fullscreenID = tile.id }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Shows this visualizer full screen")
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: Full screen

    /// One tile edge to edge. Only this tile is in the hierarchy, so the grid draws nothing while it is up; the render
    /// budget still decides whether the timeline ticks at all.
    private func stage(at index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isDrawing)) { timeline in
                let context = TileContext(
                    model: model, frame: model.poll(at: timeline.date),
                    framesPerSecond: isDrawing ? SoundRenderBudget.normal : 0,
                    tick: timeline.date.timeIntervalSinceReferenceDate)
                tiles[index].content(context)
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                if controlsOpen {
                    controlsOpen = false
                } else {
                    fullscreenID = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { drag in
                    guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                    step(drag.translation.width < 0 ? 1 : -1, from: index)
                }
            )
            #if os(macOS)
                .onContinuousHover { _ in wakeOverlay() }
            #endif

            overlay(index: index)
        }
        .focusable()
        .focused($stageFocused)
        .focusEffectDisabled()
        .onAppear { stageFocused = true }
        .onKeyPress(.leftArrow) {
            step(-1, from: index)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            step(1, from: index)
            return .handled
        }
        .onKeyPress(.space) {
            model.togglePause()
            return .handled
        }
        .onKeyPress(.escape) {
            fullscreenID = nil
            return .handled
        }
        #if os(iOS)
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
        #endif
    }

    /// A small control that fades after a few seconds idle and opens the source and song controls.
    private func overlay(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if overlayVisible || controlsOpen {
                HStack(spacing: 10) {
                    Button {
                        controlsOpen.toggle()
                        wakeOverlay()
                    } label: {
                        Label("Controls", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                    }
                    Text("\(tiles[index].id)  \(index + 1)/\(tiles.count)").font(.footnote.weight(.semibold))
                    Button {
                        fullscreenID = nil
                    } label: {
                        Label("Exit full screen", systemImage: "xmark").labelStyle(.iconOnly)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
            }
            if controlsOpen {
                controls
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 520)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.25), value: overlayVisible)
        .animation(.easeInOut(duration: 0.25), value: controlsOpen)
        .task(id: overlayTick) {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, !controlsOpen { overlayVisible = false }
        }
    }

    private func wakeOverlay() {
        overlayVisible = true
        overlayTick += 1
    }

    private func open(_ id: String) {
        if tiles.contains(where: { $0.id == id }) { fullscreenID = id }
    }

    private func step(_ delta: Int, from index: Int) {
        fullscreenID = tiles[(index + delta + tiles.count) % tiles.count].id
        wakeOverlay()
    }

    /// A real full-screen window on macOS; iOS apps are always full screen, so nothing to do there.
    private func setWindowFullScreen(_ on: Bool) {
        #if os(macOS)
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
            if on != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        #endif
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Source", selection: $model.input) {
                ForEach(GalleryInput.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning)
            if model.input == .demo { songControls }
            PaletteControls(model: model)
            if model.input == .demo { PromptView(model: model) }
            HStack {
                Button(playTitle) {
                    if model.isRunning {
                        model.togglePause()
                    } else if model.input == .file {
                        importing = true
                    } else {
                        Task { await model.start() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])
                if model.isRunning { Button("Stop") { model.stop() } }
                Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }

    private var playTitle: String {
        if model.isRunning { return model.isPaused ? "Resume" : "Pause" }
        return model.input == .file ? "Choose file…" : "Play"
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
