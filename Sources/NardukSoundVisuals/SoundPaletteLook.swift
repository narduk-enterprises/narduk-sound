import Foundation

/// A named base palette for `SoundPaletteLook`. `neon` is the library's own section-driven default, so it carries no
/// colors of its own: choosing it follows the provider.
public enum SoundPalettePreset: String, CaseIterable, Sendable, Codable, Identifiable {
    case neon, sunset, ocean, toxic, ice, candy, mono, ember

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .neon: "Neon"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .toxic: "Toxic"
        case .ice: "Ice"
        case .candy: "Candy"
        case .mono: "Mono"
        case .ember: "Ember"
        }
    }

    /// The preset's colors, or nil for `neon` (follow the provider).
    public var colors: SoundPalette? {
        func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { SIMD3(r, g, b) }
        switch self {
        case .neon: return nil
        case .sunset:
            return SoundPalette(c0: rgb(1.0, 0.55, 0.20), c1: rgb(1.0, 0.25, 0.55), c2: rgb(0.55, 0.25, 0.95))
        case .ocean:
            return SoundPalette(c0: rgb(0.05, 0.55, 0.95), c1: rgb(0.05, 0.85, 0.85), c2: rgb(0.30, 0.35, 0.95))
        case .toxic:
            return SoundPalette(c0: rgb(0.62, 1.0, 0.10), c1: rgb(0.15, 0.90, 0.35), c2: rgb(0.85, 0.95, 0.15))
        case .ice:
            return SoundPalette(c0: rgb(0.70, 0.92, 1.0), c1: rgb(0.40, 0.70, 1.0), c2: rgb(0.85, 0.80, 1.0))
        case .candy:
            return SoundPalette(c0: rgb(1.0, 0.45, 0.80), c1: rgb(0.45, 0.85, 1.0), c2: rgb(1.0, 0.90, 0.40))
        case .mono:
            return SoundPalette(c0: rgb(0.95, 0.95, 0.95), c1: rgb(0.60, 0.62, 0.66), c2: rgb(0.80, 0.82, 0.88))
        case .ember:
            // Fire without a saturated red: orange, amber and a warm gold.
            return SoundPalette(c0: rgb(1.0, 0.50, 0.08), c1: rgb(1.0, 0.72, 0.18), c2: rgb(1.0, 0.86, 0.45))
        }
    }
}

/// How the palette looks right now: an optional replacement for the section-driven colors, plus the tuning knobs.
/// `SoundVisualState.look` applies it to every visualizer at once, because every visualizer (Metal) draws
/// from `state.palette`. The default is the identity, so the default look changes no pixel.
public struct SoundPaletteLook: Equatable, Sendable, Codable {
    /// Replaces the provider's colors when set; nil follows the provider (the section table).
    public var colors: SoundPalette?
    /// Rotates every hue, in degrees, -180 ... 180.
    public var hueShift: Float
    /// Scales saturation, 0 ... 2.
    public var saturation: Float
    /// Scales brightness, 0 ... 2 (results clamp to 1).
    public var brightness: Float
    /// Hue drift in degrees per second; 0 holds still.
    public var cycle: Float

    public init(
        colors: SoundPalette? = nil, hueShift: Float = 0, saturation: Float = 1, brightness: Float = 1,
        cycle: Float = 0
    ) {
        self.colors = colors
        self.hueShift = hueShift
        self.saturation = saturation
        self.brightness = brightness
        self.cycle = cycle
    }

    public static let neutral = SoundPaletteLook()

    public init(preset: SoundPalettePreset) { self.init(colors: preset.colors) }

    /// Whether this look changes nothing (so the state can skip it entirely).
    public var isNeutral: Bool { self == .neutral }

    /// The base palette with the knobs applied. Allocation-free.
    func applied(to base: SoundPalette, time: Double) -> SoundPalette {
        let source = colors ?? base
        let shift = hueShift + cycle * Float(time.truncatingRemainder(dividingBy: 3600))
        if shift == 0 && saturation == 1 && brightness == 1 { return source }
        return SoundPalette(
            c0: Self.tuned(source.c0, shift, saturation, brightness),
            c1: Self.tuned(source.c1, shift, saturation, brightness),
            c2: Self.tuned(source.c2, shift, saturation, brightness))
    }

    private static func tuned(_ c: SIMD3<Float>, _ shift: Float, _ sat: Float, _ bright: Float) -> SIMD3<Float> {
        var (h, s, v) = hsv(c)
        h = (h + shift / 360).truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        s = min(max(s * sat, 0), 1)
        v = min(max(v * bright, 0), 1)
        return rgb(h, s, v)
    }

    static func hsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let hi = max(c.x, c.y, c.z)
        let lo = min(c.x, c.y, c.z)
        let d = hi - lo
        var h: Float = 0
        if d > 1e-6 {
            if hi == c.x {
                h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6)
            } else if hi == c.y {
                h = (c.z - c.x) / d + 2
            } else {
                h = (c.x - c.y) / d + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, hi > 1e-6 ? d / hi : 0, hi)
    }

    static func rgb(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let f = (h - h.rounded(.down)) * 6
        let i = Int(f) % 6
        let x = f - Float(Int(f))
        let p = v * (1 - s)
        let q = v * (1 - s * x)
        let t = v * (1 - s * (1 - x))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    /// A harmonious palette from a seed: a base hue plus an analogous, triad or split-complement spread, bright and
    /// saturated like the neon default. Deterministic: the same seed always gives the same look.
    public static func random(seed: UInt64) -> SoundPaletteLook {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(z >> 40) / Float(1 << 24)
        }
        let base = next()
        let offsets: (Float, Float)
        switch Int(next() * 3) % 3 {
        case 0: offsets = (1.0 / 12, 2.0 / 12)  // analogous
        case 1: offsets = (1.0 / 3, 2.0 / 3)  // triad
        default: offsets = (5.0 / 12, 7.0 / 12)  // split complement
        }
        let s = 0.65 + 0.35 * next()
        let v = 0.88 + 0.12 * next()
        return SoundPaletteLook(
            colors: SoundPalette(
                c0: rgb(base, s, v), c1: rgb(base + offsets.0, s, v), c2: rgb(base + offsets.1, s, v)))
    }
}
