import NardukSoundAnalysis
import SwiftUI
import UniformTypeIdentifiers

struct GalleryView: View {
    @Bindable var model: GalleryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var pickedFile: URL?

    /// The render budget: 60 fps while the app is on screen and playing, nothing otherwise.
    private var isDrawing: Bool { model.isRunning && scenePhase == .active }

    var body: some View {
        VStack(spacing: 0) {
            controls
            // One timeline polls one frame per tick for every card; a card polling for itself would run the analyzer
            // (and its smoothing) once per card.
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isDrawing)) { timeline in
                let frame = model.poll(at: timeline.date)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(Visualizer.all) { visualizer in
                            VisualizerCard(visualizer: visualizer, frame: frame)
                        }
                    }
                    .padding(12)
                }
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
            // `-autoplay demo|microphone` or `-autofile <path>` starts a source at launch, for smoke runs and screenshots.
            let defaults = UserDefaults.standard
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
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Source", selection: $model.input) {
                ForEach(GalleryInput.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isRunning)
            HStack {
                Button(model.isRunning ? "Stop" : (model.input == .file ? "Choose file…" : "Play")) {
                    if model.isRunning {
                        model.stop()
                    } else if model.input == .file {
                        importing = true
                    } else {
                        Task { await model.start() }
                    }
                }
                .buttonStyle(.borderedProminent)
                Text(model.status).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
    }
}

private struct VisualizerCard: View {
    let visualizer: Visualizer
    let frame: SoundFrame

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visualizer.id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { context, size in visualizer.draw(&context, size, frame) }
                .frame(height: 160)
                .accessibilityLabel(visualizer.id)
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
