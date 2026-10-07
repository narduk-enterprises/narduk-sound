import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// The spectacle visualizers (`NardukSoundVisuals/Spectacle`) as gallery tiles. Each tile owns its own
/// `SoundVisualState`, like the tunnel tile: the views advance it from their own draw loops on their own clocks, so
/// they cannot share the model's state without fighting over time. They poll `model.latestFrame`, the frame the
/// gallery's one timeline last polled, so the analyzer still runs once per tick. The rate comes from the gallery's
/// render budget through the environment.
struct ParticleFieldTile: View {
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
        ParticleFieldView(state: state) { model.latestInput }
            .environment(\.soundFramesPerSecond, framesPerSecond)
            .accessibilityLabel("Particle field")
    }
}

struct KaleidoscopeTile: View {
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
        BeatKaleidoscopeView(state: state) { model.latestInput }
            .environment(\.soundFramesPerSecond, framesPerSecond)
            .accessibilityLabel("Beat kaleidoscope")
    }
}

struct ShaderPackTile: View {
    let kind: ShaderPackKind
    let title: String
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
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
        GalleryTile(id: "Particle field") { context in
            AnyView(ParticleFieldTile(model: context.model, framesPerSecond: context.framesPerSecond))
        },
        GalleryTile(id: "Beat kaleidoscope") { context in
            AnyView(KaleidoscopeTile(model: context.model, framesPerSecond: context.framesPerSecond))
        },
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
    ]
}
