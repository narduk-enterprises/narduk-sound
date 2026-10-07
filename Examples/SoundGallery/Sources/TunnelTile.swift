import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// The Metal wobble tunnel (`NardukSoundVisuals`) as a gallery tile. It polls on its own
/// `MTKView` draw loop: `model.latestFrame` is the frame the gallery's one timeline last polled, so the analyzer still
/// runs once per tick. The frame rate comes from the gallery's render budget through the environment, so it holds still
/// when nothing plays.
struct TunnelTile: View {
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
        let _ = model.sync(state)
        if WobbleTunnelView.isSupported {
            WobbleTunnelView(state: state) { model.latestInput }
                .environment(\.soundFramesPerSecond, framesPerSecond)
                .accessibilityLabel("Wobble tunnel")
        } else {
            Text("Metal is not available on this device.").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

extension GalleryTile {
    static let tunnel = GalleryTile(id: "Wobble tunnel") { context in
        AnyView(TunnelTile(model: context.model, framesPerSecond: context.framesPerSecond))
    }
}
