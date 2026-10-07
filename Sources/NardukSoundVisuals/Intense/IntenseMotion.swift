import Foundation
import NardukMusicCore

/// The motion the dive and flyover need beyond the shared drive: how deep the fractal is and where it is headed,
/// how far the flyover has travelled and how high the drop has lifted it. A plain value advanced once per display
/// frame from `SoundVisualState` (time comes from `state.time`, so a replay repeats; a repeated frame moves
/// nothing), with no heap use. The flash and the calm level are `IntenseDrive`'s, not this struct's.
struct IntenseMotion: Equatable {
    /// How deep the fractal goes, in e-folds (about 1,100x): past this a 32-bit float runs out of precision.
    static let maxDepth: Float = 7.0
    /// Dive targets (Mandelbrot c), visited in turn, each reached from the surface of the previous dive.
    static let targets: [SIMD2<Float>] = [
        SIMD2(-0.743_643_887, 0.131_825_904), SIMD2(-0.775_683_77, 0.136_467_37), SIMD2(-0.160_701_35, 1.037_566_5),
    ]

    private(set) var lastTime: Double = -1
    /// Fractal dive: a phase whose cosine eases the depth in and out, so each dive starts and ends at the surface.
    private(set) var phase: Double = 0
    private(set) var morph: Float = 0
    /// Synthwave flyover.
    private(set) var travel: Double = 0
    private(set) var lift: Float = 0
    private var amp: Float = 1

    init(phase: Double = 0) { self.phase = phase }

    var depth: Float { Self.maxDepth * Float(0.5 - 0.5 * cos(phase)) }
    var target: SIMD2<Float> {
        let index = Int((phase / (2 * .pi)).rounded(.down))
        return Self.targets[((index % Self.targets.count) + Self.targets.count) % Self.targets.count]
    }

    /// Allocation-free (`allCases` would build an array every frame).
    static func sectionIndex(_ section: SongSection) -> Float {
        switch section {
        case .intro: 0
        case .build: 1
        case .drop: 2
        case .breakdown: 3
        case .drop2: 4
        }
    }

    /// `intensity` is `IntenseDrive.intensity`: 1, or `calmIntensity` in calm.
    @MainActor mutating func advance(_ kind: IntenseKind, state: SoundVisualState, intensity: Float) {
        advance(
            kind, time: state.time, kick: state.kick, energy: state.energy, dropAmount: state.dropAmount,
            section: state.section, intensity: intensity)
    }

    mutating func advance(
        _ kind: IntenseKind, time: Double, kick: Float, energy: Float, dropAmount: Float, section: SongSection,
        intensity: Float
    ) {
        let dt = lastTime < 0 ? 0 : Float(min(max(time - lastTime, 0), 0.1))
        lastTime = time
        guard dt > 0 else { return }
        let calm = intensity < 1
        let drop = min(dropAmount, calm ? 0.4 : 1)
        amp = 0.55 + 0.45 * min(max((intensity - IntenseDrive.calmIntensity) / (1 - IntenseDrive.calmIntensity), 0), 1)
        switch kind {
        case .fractalDive:
            phase += Double((0.12 + 0.55 * kick + 0.3 * energy + 0.5 * drop) * intensity * dt)
            let turn = Self.sectionIndex(section) * 0.45
            morph += (turn + Float(time) * 0.02 - morph) * min(1, dt * 0.8)
        case .synthwaveFlyover:
            travel += Double((5 + 12 * energy + 8 * kick) * intensity * (1 + 1.5 * lift) * dt)
            lift += (drop - lift) * min(1, dt * 1.6)
        default:
            break
        }
    }

    /// The two float4s the dive and flyover shaders read (buffer 3): depth, target x, target y, turn; then travel,
    /// lift, terrain amplitude, hue shift.
    var packed: (SIMD4<Float>, SIMD4<Float>) {
        (
            SIMD4(depth, target.x, target.y, morph),
            SIMD4(Float(travel.truncatingRemainder(dividingBy: 4096)), lift, amp, morph * 0.8)
        )
    }
}
