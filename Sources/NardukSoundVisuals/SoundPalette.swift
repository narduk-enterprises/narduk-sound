import Foundation
import NardukMusicCore

/// Three blendable neon colors that drive every visualizer (docs/sound-contract.md section 6). Visualizers take a
/// palette and never name a color; apps supply theirs. Components are 0 ... 1.
public struct SoundPalette: Equatable, Sendable, Codable {
    public var c0: SIMD3<Float>
    public var c1: SIMD3<Float>
    public var c2: SIMD3<Float>

    public init(c0: SIMD3<Float>, c1: SIMD3<Float>, c2: SIMD3<Float>) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    public func mixed(with other: SoundPalette, _ t: Float) -> SoundPalette {
        SoundPalette(c0: c0 + (other.c0 - c0) * t, c1: c1 + (other.c1 - c1) * t, c2: c2 + (other.c2 - c2) * t)
    }

    /// A blend through OKLab, so the midpoint of two hues keeps its lightness and chroma instead of going muddy the way
    /// a straight RGB mix does. `t` is 0 ... 1.
    public func mixedPerceptually(with other: SoundPalette, _ t: Float) -> SoundPalette {
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            let la = Self.oklab(a)
            let lb = Self.oklab(b)
            return Self.fromOklab(la + (lb - la) * t)
        }
        return SoundPalette(c0: mix(c0, other.c0), c1: mix(c1, other.c1), c2: mix(c2, other.c2))
    }

    static func oklab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : Foundation.pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x)
        let g = lin(c.y)
        let b = lin(c.z)
        let l = Foundation.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = Foundation.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = Foundation.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func fromOklab(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = Foundation.pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = Foundation.pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = Foundation.pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func gamma(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * Foundation.pow(x, 1 / 2.4) - 0.055
        }
        return SIMD3(gamma(r), gamma(g), gamma(b))
    }

    /// Scales each color's saturation around its luma; > 1 pushes it past the source palette.
    public func saturated(_ amount: Float) -> SoundPalette {
        func sat(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let luma = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
            let out = SIMD3<Float>(repeating: luma) + (c - SIMD3<Float>(repeating: luma)) * amount
            return out.clamped(lowerBound: SIMD3<Float>(repeating: 0), upperBound: SIMD3<Float>(repeating: 1))
        }
        return SoundPalette(c0: sat(c0), c1: sat(c1), c2: sat(c2))
    }

    /// Cyclic sample c0 -> c1 -> c2 -> c0; `t` may be any value.
    public func sample(_ t: Float) -> SIMD3<Float> {
        let f = (t - t.rounded(.down)) * 3
        let segment = Int(f) % 3
        let local = f - Float(Int(f))
        let s = local * local * (3 - 2 * local)
        switch segment {
        case 0: return c0 + (c1 - c0) * s
        case 1: return c1 + (c2 - c1) * s
        default: return c2 + (c0 - c2) * s
        }
    }
}

/// What picks the palette: a song section, or a scalar for sources with no music.
public enum SoundPaletteDriver: Sendable, Equatable {
    case section(SongSection)
    /// 0 ... 1, from the signal: `SoundVisualState` derives it from the smoothed spectral centroid for a mic or a
    /// file.
    case scalar(Float)
}

/// An app's palette table. `SoundVisualState` calls it with `.section` when a `MusicContext` is present and with
/// `.scalar` otherwise.
public protocol SoundPaletteProvider: Sendable {
    func palette(for driver: SoundPaletteDriver) -> SoundPalette
}

/// The palette the gallery and the tests use: Wirewatcher's section table, and a c0 -> c1 -> c2 sweep for a scalar.
public struct DefaultSoundPaletteProvider: SoundPaletteProvider {
    private static let cyan = SIMD3<Float>(0.13, 0.72, 0.90)
    private static let lime = SIMD3<Float>(0.62, 0.84, 0.22)
    private static let magenta = SIMD3<Float>(1.0, 0.18, 0.78)
    private static let violet = SIMD3<Float>(0.48, 0.30, 1.0)
    private static let blue = SIMD3<Float>(0.16, 0.34, 0.95)
    private static let teal = SIMD3<Float>(0.08, 0.95, 0.78)
    private static let amber = SIMD3<Float>(1.0, 0.72, 0.18)
    private static let orange = SIMD3<Float>(1.0, 0.42, 0.10)

    public init() {}

    public func palette(for driver: SoundPaletteDriver) -> SoundPalette {
        switch driver {
        case .section(let section):
            switch section {
            case .intro: return SoundPalette(c0: Self.cyan, c1: Self.blue, c2: Self.teal)
            case .build: return SoundPalette(c0: Self.cyan, c1: Self.lime, c2: Self.amber)
            case .drop: return SoundPalette(c0: Self.lime, c1: Self.magenta, c2: Self.cyan)
            case .breakdown: return SoundPalette(c0: Self.violet, c1: Self.blue, c2: Self.cyan)
            case .drop2: return SoundPalette(c0: Self.orange, c1: Self.magenta, c2: Self.lime)
            }
        case .scalar(let value):
            let base = SoundPalette(c0: Self.cyan, c1: Self.violet, c2: Self.magenta)
            let t = min(max(value, 0), 1)
            // Slide the three colors along the cycle so a rising signal visibly changes the whole palette.
            return SoundPalette(c0: base.sample(t), c1: base.sample(t + 1.0 / 3), c2: base.sample(t + 2.0 / 3))
        }
    }
}
