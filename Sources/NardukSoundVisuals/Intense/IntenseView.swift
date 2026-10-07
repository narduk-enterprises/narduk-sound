#if canImport(MetalKit) && canImport(SwiftUI)
    import MetalKit
    import NardukSoundAnalysis
    import QuartzCore
    import SwiftUI
    import os

    /// An intense visualizer (hyperspace + lasers, or fluid + glitch) in an `MTKView`. It follows the wobble tunnel's
    /// rules: shares its settled, reduced-resolution drawable (`TunnelMTKView`), polls `input` from its own draw loop,
    /// runs at the budget in `\.soundFramesPerSecond` (0 pauses on the last frame), skips a frame instead of queueing
    /// when the GPU is behind, and allocates nothing per frame once the fluid surface exists. Every full-screen flash
    /// goes through `IntenseFlashLimiter` (three a second at most) and `calm` draws none. `state` is the caller's.
    public struct IntenseView: WobbleTunnelRepresentable {
        let kind: IntenseKind
        let state: SoundVisualState
        let input: @MainActor () -> SoundVisualInput
        let calm: Bool

        public init(
            _ kind: IntenseKind, state: SoundVisualState, calm: Bool = false,
            input: @escaping @MainActor () -> SoundVisualInput
        ) {
            self.kind = kind
            self.state = state
            self.calm = calm
            self.input = input
        }

        /// False when this device cannot build the pipelines (no Metal, a shader did not compile).
        @MainActor public static var isSupported: Bool { IntenseRenderer.shared != nil }

        public func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor private func makeMetalView(context: Context) -> TunnelMTKView {
            let view = TunnelMTKView(frame: .zero, device: IntenseRenderer.shared?.device)
            view.colorPixelFormat = IntenseRenderer.pixelFormat
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            view.framebufferOnly = true
            view.enableSetNeedsDisplay = false
            view.autoResizeDrawable = false
            view.delegate = context.coordinator
            update(view, context: context)
            return view
        }

        @MainActor private func update(_ view: MTKView, context: Context) {
            context.coordinator.attach(kind: kind, state: state, input: input, calm: calm)
            let fps = context.environment.soundFramesPerSecond
            let rate = SoundRenderBudget.rate(fps)
            if rate > 0, view.preferredFramesPerSecond != rate { view.preferredFramesPerSecond = rate }
            if view.isPaused != (fps <= 0) { view.isPaused = fps <= 0 }
        }

        @MainActor private static func dismantle(_ view: MTKView) {
            view.isPaused = true
            view.delegate = nil
        }

        #if os(macOS)
            @MainActor public func makeNSView(context: Context) -> MTKView { makeMetalView(context: context) }
            @MainActor public func updateNSView(_ view: MTKView, context: Context) { update(view, context: context) }
            @MainActor public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) { dismantle(view) }
        #else
            @MainActor public func makeUIView(context: Context) -> MTKView { makeMetalView(context: context) }
            @MainActor public func updateUIView(_ view: MTKView, context: Context) { update(view, context: context) }
            @MainActor public static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) { dismantle(view) }
        #endif

        @MainActor
        public final class Coordinator: NSObject, MTKViewDelegate {
            private var kind = IntenseKind.hyperspaceLasers
            private var state: SoundVisualState?
            private var input: (@MainActor () -> SoundVisualInput)?
            private var calm = false
            private var uniforms = IntenseUniforms()
            private var limiter = IntenseFlashLimiter()
            private var surface: FeedbackSurface?
            private let inFlight = OSAllocatedUnfairLock(initialState: 0)
            static let maxInFlight = 2

            func attach(
                kind: IntenseKind, state: SoundVisualState, input: @escaping @MainActor () -> SoundVisualInput,
                calm: Bool
            ) {
                if kind != self.kind { surface = nil }
                self.kind = kind
                self.state = state
                self.input = input
                self.calm = calm
            }

            nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

            nonisolated public func draw(in view: MTKView) {
                MainActor.assumeIsolated { render(in: view) }
            }

            private func render(in view: MTKView) {
                guard let renderer = IntenseRenderer.shared, let state, let input,
                    inFlight.withLock({ $0 }) < Self.maxInFlight, let drawable = view.currentDrawable,
                    let buffer = renderer.queue.makeCommandBuffer()
                else { return }

                if kind == .fluidGlitch {
                    let size = view.drawableSize
                    if surface == nil || surface?.width != Int(size.width) || surface?.height != Int(size.height) {
                        surface = FeedbackSurface(
                            device: renderer.device, width: Int(size.width), height: Int(size.height))
                    }
                    if surface == nil { return }
                }

                state.update(input(), now: CACurrentMediaTime(), options: SoundVisualOptions(calm: calm))
                let drive = IntenseDrive(state: state, limiter: &limiter)
                renderer.encode(
                    kind, buffer: buffer, target: drawable.texture, state: state, drive: drive, uniforms: &uniforms,
                    surface: surface)
                inFlight.withLock { $0 += 1 }
                let inFlight = self.inFlight
                buffer.addCompletedHandler { _ in inFlight.withLock { $0 -= 1 } }
                buffer.present(drawable)
                buffer.commit()
            }
        }
    }
#endif
