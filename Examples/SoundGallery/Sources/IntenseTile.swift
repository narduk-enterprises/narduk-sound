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
