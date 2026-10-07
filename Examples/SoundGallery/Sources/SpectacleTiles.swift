import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// The spectacle visualizers (`NardukSoundVisuals/Spectacle`) as gallery tiles. Each tile owns its own
/// `SoundVisualState`, like the tunnel tile: the views advance it from their own draw loops on their own clocks, so
/// they cannot share the model's state without fighting over time. They poll `model.latestFrame`, the frame the
/// gallery's one timeline last polled, so the analyzer still runs once per tick. The rate comes from the gallery's
/// render budget through the environment.
struct ShaderPackTile: View {
    let kind: ShaderPackKind
    let title: String
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
        let _ = model.sync(state)
        if ShaderPackView.isSupported {
            ShaderPackView(kind, state: state) { model.latestInput }
                .environment(\.soundFramesPerSecond, framesPerSecond)
                .accessibilityLabel(title)
        } else {
            Text("Metal is not available on this device.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

extension GalleryTile {
    /// The new visualizers, in the order the gallery shows them.
    static let spectacle: [GalleryTile] = [
        GalleryTile(id: "Feedback (Milkdrop)") { context in
            AnyView(
                ShaderPackTile(
                    kind: .feedback, title: "Feedback", model: context.model, framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Plasma") { context in
            AnyView(
                ShaderPackTile(
                    kind: .plasma, title: "Plasma", model: context.model, framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Warp grid") { context in
            AnyView(
                ShaderPackTile(
                    kind: .warpGrid, title: "Warp grid", model: context.model, framesPerSecond: context.framesPerSecond)
            )
        },
        GalleryTile(id: "Starfield") { context in
            AnyView(
                ShaderPackTile(
                    kind: .starfield, title: "Starfield", model: context.model, framesPerSecond: context.framesPerSecond
                ))
        },
        GalleryTile(id: "Bass blobs") { context in
            AnyView(
                ShaderPackTile(
                    kind: .bassBlobs, title: "Bass blobs", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Aurora curtains") { context in
            AnyView(
                ShaderPackTile(
                    kind: .aurora, title: "Aurora curtains", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Aurora waves") { context in
            AnyView(
                ShaderPackTile(
                    kind: .auroraWaves, title: "Aurora waves", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Mesh wave") { context in
            AnyView(
                ShaderPackTile(
                    kind: .meshWave, title: "Mesh wave", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Solar flare") { context in
            AnyView(
                ShaderPackTile(
                    kind: .solarFlare, title: "Solar flare", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Ocean waves") { context in
            AnyView(
                ShaderPackTile(
                    kind: .oceanWaves, title: "Ocean waves", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Fireworks") { context in
            AnyView(
                ShaderPackTile(
                    kind: .fireworks, title: "Fireworks", model: context.model,
                    framesPerSecond: context.framesPerSecond))
        },
    ]
}
