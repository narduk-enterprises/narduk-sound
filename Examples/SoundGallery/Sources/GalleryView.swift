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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var importing = false
    @State private var pickedFile: URL?
    /// The tile shown alone, edge to edge; nil shows the grid.
    @State private var fullscreenID: String?
    @State private var overlayVisible = true
    @State private var controlsOpen = false
    /// The iPhone's controls sheet; a Mac or iPad shows the strip as a sidebar instead.
    @State private var sheetOpen = false
    @State private var overlayTick = 0
    @FocusState private var stageFocused: Bool

    private let builtInTiles = GalleryTile.all
    /// The drop-in `.metal` visualizers (narduk-libs#1665): watched, so a save updates the running gallery.
    @State private var plugins = IntensePluginLibrary()
    private var tiles: [GalleryTile] { builtInTiles + plugins.entries.map(GalleryTile.plugin) }

    /// The hero's tile: the first one, shown large above the grid instead of in it.
    private var hero: GalleryTile { tiles[0] }

    /// A sidebar on a Mac and a regular-width iPad; an iPhone (compact) gets a sheet.
    private var usesSidebar: Bool {
        #if os(macOS)
            true
        #else
            sizeClass == .regular
        #endif
    }

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
            plugins.start()
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
        Group {
            if usesSidebar {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(GalleryTheme.edge)
                    showcase
                }
            } else {
                showcase
                    .sheet(isPresented: $sheetOpen) {
                        ScrollView {
                            ControlStrip(model: model, importing: $importing, plugins: plugins, showsTransport: false)
                        }
                        .background(GalleryPalette.background)
                        .presentationDetents([.medium, .large])
                    }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sound Gallery").font(GalleryTheme.title)
                    .padding([.horizontal, .top], GalleryTheme.Space.m)
                ControlStrip(model: model, importing: $importing, plugins: plugins)
            }
        }
        .frame(width: GalleryTheme.sidebarWidth)
        .background(Color.black.opacity(0.25))
    }

    /// The hero and the card grid on one timeline: it polls one frame per tick for every card (a card polling for itself
    /// would run the analyzer and its smoothing once per card).
    private var showcase: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isDrawing)) { timeline in
            let context = TileContext(
                model: model, frame: model.poll(at: timeline.date),
                framesPerSecond: isDrawing ? SoundRenderBudget.normal : 0,
                tick: timeline.date.timeIntervalSinceReferenceDate)
            ScrollView {
                VStack(alignment: .leading, spacing: GalleryTheme.Space.l) {
                    if !usesSidebar { compactHeader }
                    heroCard(context)
                    Text("Visualizers").font(GalleryTheme.sectionTitle).foregroundStyle(.secondary)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260), spacing: GalleryTheme.Space.m)],
                        spacing: GalleryTheme.Space.m
                    ) {
                        ForEach(tiles.dropFirst()) { tile in
                            TileCard(tile: tile, context: context)
                                .onTapGesture { fullscreenID = tile.id }
                        }
                    }
                }
                .padding(GalleryTheme.Space.l)
            }
        }
    }

    /// The iPhone's top row: the title, play or stop, and the controls sheet.
    private var compactHeader: some View {
        HStack(spacing: GalleryTheme.Space.m) {
            Text("Sound Gallery").font(GalleryTheme.title)
            Spacer(minLength: 0)
            TransportControls(model: model, importing: $importing, compact: true)
            Button {
                sheetOpen = true
            } label: {
                Label("Controls", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
        }
    }

    /// The now-playing hero: the first tile large, with the state over it. While nothing plays it says how to start.
    private func heroCard(_ context: TileContext) -> some View {
        ZStack(alignment: .topLeading) {
            hero.content(context)
                .frame(height: GalleryTheme.heroHeight)
                .clipShape(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
            LinearGradient(
                colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: GalleryTheme.Space.xs) {
                GalleryBadge(
                    text: model.isRunning ? "Now playing" : "Ready",
                    tint: model.isRunning ? GalleryPalette.low : .white)
                Text(model.isRunning ? model.status : "Press Play to start the music.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
            .padding(GalleryTheme.Space.m)
        }
        .frame(height: GalleryTheme.heroHeight)
        .overlay(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius).stroke(GalleryTheme.edge, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
        .onTapGesture { fullscreenID = hero.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(hero.id), now playing")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this visualizer full screen")
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
                ScrollView { ControlStrip(model: model, importing: $importing, plugins: plugins, spaceShortcut: false) }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
                    .frame(maxWidth: 420, maxHeight: 520)
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
}
