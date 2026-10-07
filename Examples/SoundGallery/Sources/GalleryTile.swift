import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// What a tile draws from on one tick: the gallery's model (for a view that polls on its own clock), the frame the
/// gallery's single timeline just polled, and the render budget (0 means hold still).
struct TileContext {
    let model: GalleryModel
    let frame: SoundFrame
    let framesPerSecond: Int
    /// Changes every frame, so a Canvas whose only input is a reference-type state still redraws.
    let tick: Double
}

/// One visualizer the gallery can show in the grid or alone, full screen. A Canvas tile draws from `context.frame`; a
/// Metal tile takes its rate from `context.framesPerSecond`. Adding a visualizer to the gallery is adding a tile here.
struct GalleryTile: Identifiable {
    let id: String
    /// A Metal tile (drawn on the GPU) rather than a Canvas one: the card's kind badge.
    var isMetal = false
    /// The card's height in the grid; full screen ignores it.
    var gridHeight: CGFloat = 160
    let content: @MainActor (TileContext) -> AnyView

    var metal: GalleryTile {
        var copy = self
        copy.isMetal = true
        return copy
    }

    static var all: [GalleryTile] {
        ([tunnel] + spectacle + intense).map(\.metal)
            + Visualizer.all.map { visualizer in
                GalleryTile(id: visualizer.id) { context in
                    let palette = context.model.cardPalette
                    return AnyView(
                        Canvas { canvas, size in
                            _ = context.tick
                            visualizer.draw(&canvas, size, context.frame, palette)
                        }
                        .accessibilityLabel(visualizer.id))
                }
            }
            + SoundVisualizerKind.allCases.map { kind in
                GalleryTile(id: kind.title, gridHeight: kind == .pads ? 280 : 160) { context in
                    AnyView(
                        Canvas { canvas, size in
                            _ = context.tick
                            SoundVisualizers.draw(kind, &canvas, size, context.model.visualState)
                        }
                        .accessibilityLabel(kind.title))
                }
            }
    }
}
