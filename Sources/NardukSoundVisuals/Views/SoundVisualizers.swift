#if canImport(SwiftUI)
    import SwiftUI

    /// The Canvas visualizers NardukSoundVisuals ships. Each draws from a `SoundVisualState` only.
    public enum SoundVisualizerKind: String, CaseIterable, Identifiable, Sendable {
        /// 64 log-spaced bars with additive glow, peak-hold caps and a reflection (from Data Beats).
        case spectrum
        /// The waveform on a graticule, triggered on a rising zero crossing (Data Beats).
        case scope
        /// The wobble LFO dial with peak and RMS meters (Data Beats).
        case wobbleMeter
        /// One flashing pad per instrument (Data Beats).
        case pads
        /// Symmetric spectrum over a beat-scrolling neon floor (Wirewatcher).
        case mirror
        /// Radial spectrum around a pulsing core with a waveform ring (Wirewatcher).
        case halo
        /// X/Y Lissajous with persistence trails and the hit FX field (Wirewatcher).
        case phosphor
        /// A note waterfall: the notes the music plays (or the analysis chroma, for raw audio) scrolling past a playhead.
        case pianoRoll
        /// The 12 pitch classes around a wheel, growing as they sound, with the key marked.
        case pitchWheel
        /// A spiral galaxy whose arms are the spectrum, bass at the core and highs at the rim, with a waveform
        /// accretion ring, snare shock rings and a differentially rotating starfield.
        case vortex
        /// A neon wireframe landscape: spectrum and waveform history raise the ridges, and travel scrolls the grid.
        case audioTerrain

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .spectrum: "Spectrum"
            case .scope: "Scope"
            case .wobbleMeter: "Wobble meter"
            case .pads: "Pads"
            case .mirror: "Mirror"
            case .halo: "Halo"
            case .phosphor: "Phosphor"
            case .pianoRoll: "Piano roll"
            case .pitchWheel: "Pitch wheel"
            case .vortex: "Vortex"
            case .audioTerrain: "Audio terrain"
            }
        }

        /// True when the visualizer fills its own backdrop; the others draw over whatever the host supplies.
        public var paintsBackdrop: Bool {
            switch self {
            case .mirror, .halo, .phosphor, .pianoRoll, .pitchWheel, .vortex, .audioTerrain: true
            default: false
            }
        }
    }

    /// Draw functions over a `SoundVisualState`, for hosts that own their own `Canvas` (the gallery's cards, an
    /// offline image renderer). `SoundVisualizerView` is the same thing with its own clock.
    @MainActor public enum SoundVisualizers {
        public static func draw(
            _ kind: SoundVisualizerKind, _ context: inout GraphicsContext, _ size: CGSize, _ state: SoundVisualState,
            style: SoundVisualizerStyle = SoundVisualizerStyle()
        ) {
            let style = style.tinted(by: state)
            switch kind {
            case .spectrum: spectrum(&context, size, state)
            case .scope: scope(&context, size, state)
            case .wobbleMeter: wobbleMeter(&context, size, state, style)
            case .pads: pads(&context, size, state, style)
            case .mirror: mirror(&context, size, state, style)
            case .halo: halo(&context, size, state, style)
            case .phosphor: phosphor(&context, size, state, style)
            case .pianoRoll: pianoRoll(&context, size, state, style)
            case .pitchWheel: pitchWheel(&context, size, state, style)
            case .vortex: vortex(&context, size, state, style)
            case .audioTerrain: audioTerrain(&context, size, state, style)
            }
        }
    }

    /// One visualizer on its own `TimelineView` clock. It polls `input` each tick and advances the shared state, which
    /// is idempotent per display frame, so several views over one state do not step it twice. The tick rate comes from
    /// `soundFramesPerSecond`, never from the display (docs/sound-contract.md sections 4 and 5).
    public struct SoundVisualizerView: View {
        private let kind: SoundVisualizerKind
        private let state: SoundVisualState
        private let input: @MainActor () -> SoundVisualInput
        private let options: SoundVisualOptions
        private let style: SoundVisualizerStyle
        @Environment(\.soundFramesPerSecond) private var framesPerSecond

        public init(
            _ kind: SoundVisualizerKind, state: SoundVisualState, options: SoundVisualOptions = SoundVisualOptions(),
            style: SoundVisualizerStyle = SoundVisualizerStyle(), input: @escaping @MainActor () -> SoundVisualInput
        ) {
            self.kind = kind
            self.state = state
            self.options = options
            self.style = style
            self.input = input
        }

        public var body: some View {
            TimelineView(SoundRenderBudget.schedule(framesPerSecond)) { timeline in
                Canvas { context, size in
                    state.update(
                        input(), now: timeline.date.timeIntervalSinceReferenceDate, options: options)
                    SoundVisualizers.draw(kind, &context, size, state, style: style)
                }
            }
        }
    }
#endif
