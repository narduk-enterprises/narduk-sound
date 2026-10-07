import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// The Metal wobble tunnel (`NardukSoundVisuals`). Unlike the Canvas cards it polls on its own `MTKView` draw loop:
/// `model.latestFrame` is the frame the gallery's one timeline last polled, so the analyzer still runs once per tick.
/// The frame rate comes from the gallery's render budget through the environment, so it holds still when nothing plays.
struct TunnelCard: View {
    let model: GalleryModel
    let framesPerSecond: Int
    @State private var state = SoundVisualState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wobble tunnel (Metal)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if WobbleTunnelView.isSupported {
                    WobbleTunnelView(state: state) { SoundVisualInput(frame: model.latestFrame) }
                        .environment(\.soundFramesPerSecond, framesPerSecond)
                } else {
                    Text("Metal is not available on this device.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Wobble tunnel")
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
