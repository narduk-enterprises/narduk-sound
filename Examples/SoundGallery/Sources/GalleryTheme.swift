import SwiftUI

/// The gallery's spacing, shape and type tokens, so every card, strip and overlay agrees. Colors stay in
/// `GalleryPalette` (the visualizers use them too).
enum GalleryTheme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
    }

    static let cardRadius: CGFloat = 16
    static let previewRadius: CGFloat = 12
    static let sidebarWidth: CGFloat = 320
    static let heroHeight: CGFloat = 240

    /// A card or panel fill, and its hairline edge.
    static let surface = Color.white.opacity(0.06)
    static let edge = Color.white.opacity(0.10)

    static let title = Font.system(.title2, design: .rounded).weight(.bold)
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let sectionTitle = Font.caption.weight(.semibold).smallCaps()
    static let badge = Font.caption2.weight(.bold)
}

/// A rounded panel: the one card shape the gallery uses.
struct GalleryPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(GalleryTheme.surface, in: RoundedRectangle(cornerRadius: GalleryTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: GalleryTheme.cardRadius).stroke(GalleryTheme.edge, lineWidth: 1))
    }
}

extension View {
    func galleryPanel() -> some View { modifier(GalleryPanel()) }
}

/// A small pill: a tile's kind, or the now-playing marker.
struct GalleryBadge: View {
    let text: String
    var tint: Color = .white.opacity(0.7)

    var body: some View {
        Text(text.uppercased())
            .font(GalleryTheme.badge)
            .tracking(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
