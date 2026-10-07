import SwiftUI

/// One visualizer as a card: a live preview over a footer with its title and kind badge. Every grid cell and the hero
/// use it, so they all share one shape.
struct TileCard: View {
    let tile: GalleryTile
    let context: TileContext
    var previewHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tile.content(context)
                .frame(height: previewHeight ?? tile.gridHeight)
                .clipShape(RoundedRectangle(cornerRadius: GalleryTheme.previewRadius))
                .padding(GalleryTheme.Space.s)
            HStack {
                Text(tile.id).font(GalleryTheme.cardTitle).lineLimit(1)
                Spacer(minLength: GalleryTheme.Space.s)
                GalleryBadge(text: "Metal", tint: GalleryPalette.high)
            }
            .padding(.horizontal, GalleryTheme.Space.m)
            .padding(.bottom, GalleryTheme.Space.m)
            .padding(.top, GalleryTheme.Space.xs)
        }
        .galleryPanel()
        .contentShape(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows this visualizer full screen")
    }
}
