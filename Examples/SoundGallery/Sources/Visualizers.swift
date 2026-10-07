import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI

/// The gallery's palette: a deep background and three accents. Visualizers take colors, never hard-code them.
enum GalleryPalette {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let low = Color(red: 0.98, green: 0.28, blue: 0.45)
    static let mid = Color(red: 0.99, green: 0.76, blue: 0.20)
    static let high = Color(red: 0.25, green: 0.85, blue: 0.95)

    /// A c0 -> c1 -> c2 sweep over 0 ... 1.
    static func color(_ palette: SoundPalette, at position: Double) -> Color {
        let t = Float(min(max(position, 0), 1))
        let c =
            t < 0.5
            ? palette.c0 + (palette.c1 - palette.c0) * (t * 2)
            : palette.c1 + (palette.c2 - palette.c1) * ((t - 0.5) * 2)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }
}
