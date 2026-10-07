import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// What a tile draws from on one tick: the gallery's model (for a view that polls on its own clock), the frame the
/// gallery's single timeline just polled, and the render budget (0 means hold still).
struct TileContext {
    let model: GalleryModel
    let frame: SoundFrame
    let framesPerSecond: Int
    /// Changes every frame.
    let tick: Double
}

/// One visualizer the gallery can show in the grid or alone, full screen. Every tile is Metal and takes its rate from
/// `context.framesPerSecond`. Adding a visualizer to the gallery is adding a tile here.
struct GalleryTile: Identifiable {
    let id: String
    /// The card's height in the grid; full screen ignores it.
    var gridHeight: CGFloat = 160
    let content: @MainActor (TileContext) -> AnyView

    /// Every tile is Metal: the Intense kinds (the former Canvas visualizers are ports among them), the tunnel, the
    /// shader pack, and the plugins the gallery loads at run time.
    static var all: [GalleryTile] { [tunnel] + spectacle + intense }
}
