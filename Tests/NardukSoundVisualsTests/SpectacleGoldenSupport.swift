#if canImport(SwiftUI) && canImport(CoreGraphics)
    import CoreGraphics
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI

    @testable import NardukSoundVisuals

    /// Renders a fixed state to an image and reduces it to a coarse luminance grid, so a golden survives the small
    /// anti-aliasing differences between machines but fails when the picture changes.
    enum SpectacleGolden {
        static let grid = 8

        /// A busy, deterministic state: a kick-heavy drop, advanced a fixed number of frames.
        @MainActor static func busyState() -> SoundVisualState {
            let state = SoundVisualState(seed: 2026)
            var now = 1.0
            for i in 0..<45 {
                var counts = HitCounters()
                for _ in 0..<(i / 3) { counts.record(.kick) }
                for _ in 0..<(i / 6) { counts.record(.snare) }
                for _ in 0..<(i / 2) { counts.record(.hat) }
                let music = MusicContext(hitCounts: counts, step: i / 3, section: .drop, energy: 0.85, isRunning: true)
                state.update(SoundVisualInput(frame: Script.frame(UInt64(i + 1), level: 0.6), music: music), now: now)
                now += 1.0 / 60
            }
            return state
        }

        /// The mean luminance of each cell of a `grid` x `grid` split, row-major, 0 ... 1; nil when the platform
        /// cannot render.
        @MainActor static func signature<Content: View>(of content: Content, size: CGSize) -> [Double]? {
            let renderer = ImageRenderer(
                content: content.frame(width: size.width, height: size.height).background(Color.black))
            renderer.scale = 1
            guard let image = renderer.cgImage else { return nil }
            let width = image.width
            let height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drew else { return nil }
            var sums = [Double](repeating: 0, count: grid * grid)
            var counts = [Double](repeating: 0, count: grid * grid)
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let luma =
                        (0.2126 * Double(pixels[o]) + 0.7152 * Double(pixels[o + 1]) + 0.0722 * Double(pixels[o + 2]))
                        / 255
                    let cell = (y * grid / height) * grid + (x * grid / width)
                    sums[cell] += luma
                    counts[cell] += 1
                }
            }
            return zip(sums, counts).map { $0 / max($1, 1) }
        }

        static func matches(_ actual: [Double], _ golden: [Double], tolerance: Double = 0.05) -> Bool {
            actual.count == golden.count && zip(actual, golden).allSatisfy { abs($0 - $1) <= tolerance }
        }
    }
#endif
