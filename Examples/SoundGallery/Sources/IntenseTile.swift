import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// An intense Metal visualizer (`NardukSoundVisuals`) as a gallery tile. Like the tunnel it polls on its own `MTKView`
/// draw loop from `model.latestInput` (the frame and, for the demo song, its music, so the drop reaches it) and takes
/// its rate from the gallery's render budget. Reduce Motion is the calm level: no flash, strobe or glitch, and slower
/// motion. Every flash is capped at three a second inside the view.
struct IntenseTile: View {
    let kind: IntenseKind
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = model.sync(state)
        if IntenseView.isSupported {
            IntenseView(kind, state: state, calm: reduceMotion) { model.latestInput }
                .environment(\.soundFramesPerSecond, framesPerSecond)
                .accessibilityLabel(kind.title)
        } else {
            Text("Metal is not available on this device.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

extension GalleryTile {
    static let intense: [GalleryTile] = IntenseKind.allCases.map { kind in
        GalleryTile(id: kind.title) { context in
            AnyView(IntenseTile(kind: kind, model: context.model, framesPerSecond: context.framesPerSecond))
        }
    }
}

/// A drop-in plugin (narduk-libs#1665): the file's visualizer once it compiles, its compiler error on the tile when
/// it does not. Saving the file replaces `entry`, so the running tile redraws with the new shader.
extension GalleryTile {
    static func plugin(_ entry: IntensePluginEntry) -> GalleryTile {
        GalleryTile(id: "\(entry.title) (plugin)") { context in
            if let kind = entry.kind, entry.error == nil {
                return AnyView(
                    IntenseTile(kind: kind, model: context.model, framesPerSecond: context.framesPerSecond))
            }
            return AnyView(PluginErrorTile(file: entry.id, message: entry.error ?? "Not loaded."))
        }
    }
}

private struct PluginErrorTile: View {
    let file: String
    let message: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Label(file, systemImage: "exclamationmark.triangle.fill").font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.85))
        .accessibilityLabel("\(file) failed to compile")
    }
}
