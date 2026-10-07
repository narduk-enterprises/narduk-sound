import Foundation

/// An intense visualizer (narduk-libs#1615): an id, a title and the fragment function that draws it. The built-ins
/// are the `static let`s below and share the library `IntenseRenderer` compiles at start-up; a plugin
/// (`IntenseKind.plugin`, narduk-libs#1665) carries its own MSL source, which the renderer compiles into a library
/// of its own after the shared `IntenseShaderCommon` and `IntenseEffects`, so a broken plugin cannot take another
/// visualizer down. Equality includes the source, so saving a plugin file makes it a new kind and a running view
/// rebuilds its pipeline.
public struct IntenseKind: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// The fragment function drawn to the screen (for the fluid pair, the glitch pass).
    let fragment: String
    /// A first pass that writes the feedback texture the main fragment reads (fluid + glitch only).
    let feedbackFragment: String?
    /// The plugin's MSL, or nil for a built-in.
    let pluginSource: String?
    /// The aux buffers the kind reads (`IntenseAux.Needs` raw bits: 1 scalars, 2 history, 4 roll); 0 for none.
    let auxMask: Int

    init(
        id: String, title: String, fragment: String, feedbackFragment: String? = nil, pluginSource: String? = nil,
        auxMask: Int = 0
    ) {
        self.id = id
        self.title = title
        self.fragment = fragment
        self.feedbackFragment = feedbackFragment
        self.pluginSource = pluginSource
        self.auxMask = auxMask
    }

    /// A kind drawn by `fragment` in `source`, a drop-in plugin. `id` names the file, so a rename is a new tile.
    public static func plugin(id: String, title: String, fragment: String, source: String) -> IntenseKind {
        IntenseKind(id: "plugin:" + id, title: title, fragment: fragment, pluginSource: source)
    }

    /// The id, kept so `kind.rawValue` call sites written for the old enum still compile.
    public var rawValue: String { id }

    public var isPlugin: Bool { pluginSource != nil }
    var usesFeedback: Bool { feedbackFragment != nil }

    public static let hyperspaceLasers = IntenseKind(
        id: "hyperspaceLasers", title: "Hyperspace + lasers", fragment: "hyperspaceFragment")
    /// Iridescent fluid advected frame to frame, then glitched (RGB split, tearing, block shifts).
    public static let fluidGlitch = IntenseKind(
        id: "fluidGlitch", title: "Fluid + glitch", fragment: "glitchFragment", feedbackFragment: "fluidFragment")
    /// A Mandelbrot dive: bass pushes the zoom, section changes turn the picture and shift the colour.
    public static let fractalDive = IntenseKind(
        id: "fractalDive", title: "Fractal dive", fragment: "fractalDiveFragment")
    /// A neon grid terrain under a striped sun: the spectrum raises the hills, the drop lifts off.
    public static let synthwaveFlyover = IntenseKind(
        id: "synthwaveFlyover", title: "Synthwave flyover", fragment: "synthwaveFragment")
    /// Iridescent liquid filaments and droplets splashing out of a core: bass sets the reach, highs the spray.
    public static let liquidSplash = IntenseKind(
        id: "liquidSplash", title: "Liquid splash", fragment: "liquidSplashFragment")
    /// A close-up star: granulated photosphere, sunspots, spicules, corona streamers, prominences and solar wind.
    public static let sun = IntenseKind(id: "sun", title: "Sun", fragment: "sunFragment")
    /// The 64 bands as glass tubes of liquid light on a mirror floor, peak beads floating above: bass swells the low tubes, highs stand tall and shower dust.
    public static let spectrum = IntenseKind(
        id: "spectrum", title: "Spectrum", fragment: "spectrumMetalFragment", auxMask: 1)
    /// The waveform as a phosphor beam on curved CRT glass, with receding history traces.
    public static let scope = IntenseKind(
        id: "scope", title: "Scope", fragment: "scopeMetalFragment", auxMask: 3)
    /// A glossy dial with the cutoff arc and the LFO needle, beside LED peak and RMS meters.
    public static let wobbleMeter = IntenseKind(
        id: "wobbleMeter", title: "Wobble meter", fragment: "wobbleMeterMetalFragment", auxMask: 1)
    /// One lit glass pad per instrument, with a hot core, a spill into its neighbours and a shock ring.
    public static let pads = IntenseKind(
        id: "pads", title: "Pads", fragment: "padsMetalFragment", auxMask: 1)
    /// Symmetric neon slabs over a beat-rolling neon floor and a waveform horizon.
    public static let mirror = IntenseKind(
        id: "mirror", title: "Mirror", fragment: "mirrorMetalFragment", auxMask: 1)
    /// A radial spectrum of lit needles around a glossy plasma core with a waveform ring, beat rings and shed sparks.
    public static let halo = IntenseKind(
        id: "halo", title: "Halo", fragment: "haloMetalFragment", auxMask: 1)
    /// A stereo-goniometer Lissajous with persistence trails on a lit CRT graticule.
    public static let phosphor = IntenseKind(
        id: "phosphor", title: "Phosphor", fragment: "phosphorMetalFragment", auxMask: 3)
    /// A note waterfall of lit glass bars flowing into a keyboard.
    public static let pianoRoll = IntenseKind(
        id: "pianoRoll", title: "Piano roll", fragment: "pianoRollMetalFragment", auxMask: 5)
    /// Twelve glass petals around a lit core, a chord polygon and the key marked.
    public static let pitchWheel = IntenseKind(
        id: "pitchWheel", title: "Pitch wheel", fragment: "pitchWheelMetalFragment", auxMask: 1)
    /// A spiral galaxy of lit gas and shaded beads wound from the spectrum: bass at the core, highs at the rim, a waveform accretion ring, snare shock rings.
    public static let vortex = IntenseKind(
        id: "vortex", title: "Vortex", fragment: "vortexMetalFragment", auxMask: 1)
    /// A neon landscape of lit ridges rolling toward the viewer under a banded low sun.
    public static let audioTerrain = IntenseKind(
        id: "audioTerrain", title: "Audio terrain", fragment: "audioTerrainMetalFragment", auxMask: 3)
    /// The kick-driven particle field: a core glow, a ring and sparks thrown on every kick, streaks on snares, blocks on hats.
    public static let particleField = IntenseKind(
        id: "particleField", title: "Particle field", fragment: "particleFieldMetalFragment", auxMask: 8)
    /// A beat tunnel seen through a kaleidoscope: rings rush out on the beat and the spectrum folds into spinning petals.
    public static let kaleidoscope = IntenseKind(
        id: "kaleidoscope", title: "Beat kaleidoscope", fragment: "kaleidoscopeMetalFragment")

    /// The built-ins, in gallery order. Plugins are loaded at run time and are not listed here.
    public static let allCases: [IntenseKind] = [
        .hyperspaceLasers, .fluidGlitch, .fractalDive, .synthwaveFlyover, .liquidSplash, .sun,
        .spectrum, .vortex, .halo, .scope, .wobbleMeter, .pads, .mirror, .phosphor, .pianoRoll, .pitchWheel,
        .audioTerrain, .particleField, .kaleidoscope,
    ]
}
