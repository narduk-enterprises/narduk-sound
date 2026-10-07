#if canImport(MetalKit) && canImport(SwiftUI)
    import MetalKit
    import NardukSoundAnalysis
    import QuartzCore
    import SwiftUI
    import os

    #if os(macOS)
        typealias WobbleTunnelRepresentable = NSViewRepresentable
    #else
        typealias WobbleTunnelRepresentable = UIViewRepresentable
    #endif

    /// The hero "wobble tunnel": a Metal fragment shader in an `MTKView`, ported from Wirewatcher. It runs at the
    /// frame budget the host sets in `\.soundFramesPerSecond` (60 fps at most; 0 pauses on the last frame), polls
    /// `input` from the view's own draw loop (docs/sound-contract.md section 4, never observed), and renders below
    /// native resolution. The draw path allocates nothing per frame and writes nothing SwiftUI observes.
    ///
    /// `state` is the caller's, so several visualizers can share one smoothed state; the tunnel advances it with
    /// `update`, which is idempotent per display frame.
    public struct WobbleTunnelView: WobbleTunnelRepresentable {
        let state: SoundVisualState
        let input: @MainActor () -> SoundVisualInput
        let calm: Bool

        public init(
            state: SoundVisualState, calm: Bool = false, input: @escaping @MainActor () -> SoundVisualInput
        ) {
            self.state = state
            self.calm = calm
            self.input = input
        }

        /// False when this device cannot create the tunnel pipeline (no Metal, shader did not compile).
        @MainActor public static var isSupported: Bool { WobbleTunnelRenderer.shared != nil }

        public func makeCoordinator() -> Coordinator { Coordinator() }

        @MainActor private func makeMetalView(context: Context) -> TunnelMTKView {
            let view = TunnelMTKView(frame: .zero, device: WobbleTunnelRenderer.shared?.device)
            view.colorPixelFormat = WobbleTunnelRenderer.pixelFormat
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            view.framebufferOnly = true
            view.enableSetNeedsDisplay = false
            view.autoResizeDrawable = false
            view.delegate = context.coordinator
            update(view, context: context)
            return view
        }

        @MainActor private func update(_ view: MTKView, context: Context) {
            context.coordinator.attach(state: state, input: input, calm: calm)
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
            private var state: SoundVisualState?
            private var input: (@MainActor () -> SoundVisualInput)?
            private var calm = false
            private var uniforms = WobbleTunnelUniforms()
            /// Command buffers the GPU has not finished. When the compositor falls behind, the draw skips a frame
            /// instead of queueing more work or blocking the main thread in `nextDrawable` (up to a second each).
            private let inFlight = OSAllocatedUnfairLock(initialState: 0)
            static let maxInFlight = 2

            func attach(state: SoundVisualState, input: @escaping @MainActor () -> SoundVisualInput, calm: Bool) {
                self.state = state
                self.input = input
                self.calm = calm
            }

            nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

            nonisolated public func draw(in view: MTKView) {
                MainActor.assumeIsolated { render(in: view) }
            }

            private func render(in view: MTKView) {
                guard let renderer = WobbleTunnelRenderer.shared, let state, let input,
                    inFlight.withLock({ $0 }) < Self.maxInFlight,
                    let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                    let buffer = renderer.queue.makeCommandBuffer(),
                    let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
                else { return }

                state.update(input(), now: CACurrentMediaTime(), options: SoundVisualOptions(calm: calm))
                renderer.encode(into: encoder, size: view.drawableSize, state: state, uniforms: &uniforms)
                encoder.endEncoding()
                inFlight.withLock { $0 += 1 }
                let inFlight = self.inFlight
                buffer.addCompletedHandler { _ in inFlight.withLock { $0 -= 1 } }
                buffer.present(drawable)
                buffer.commit()
            }
        }
    }

    /// An `MTKView` that keeps its drawable at `WobbleTunnelDrawableSizer`'s size, re-sized only once a change settles.
    final class TunnelMTKView: MTKView {
        static let renderScale: CGFloat = 0.75

        private var sizer = WobbleTunnelDrawableSizer()
        private var settleTask: Task<Void, Never>?

        #if os(macOS)
            override func setFrameSize(_ newSize: NSSize) {
                super.setFrameSize(newSize)
                resizeDrawable()
            }

            override func viewDidChangeBackingProperties() {
                super.viewDidChangeBackingProperties()
                resizeDrawable()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                windowChanged(hasWindow: window != nil)
            }

            private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }
        #else
            override func layoutSubviews() {
                super.layoutSubviews()
                resizeDrawable()
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                windowChanged(hasWindow: window != nil)
            }

            private var backingScale: CGFloat { window?.screen.scale ?? contentScaleFactor }
        #endif

        private func windowChanged(hasWindow: Bool) {
            if hasWindow {
                resizeDrawable()
            } else {
                settleTask?.cancel()
                settleTask = nil
            }
        }

        private func resizeDrawable() {
            let target = WobbleTunnelDrawableSizer.target(
                points: bounds.size, backingScale: backingScale, renderScale: Self.renderScale)
            if let size = sizer.propose(target, at: CACurrentMediaTime()) {
                if drawableSize != size { drawableSize = size }
                return
            }
            guard sizer.pending != nil, settleTask == nil else { return }
            settleTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(WobbleTunnelDrawableSizer.settleSeconds))
                    guard !Task.isCancelled else { return }
                    if let size = self.sizer.settle(at: CACurrentMediaTime()), self.drawableSize != size {
                        self.drawableSize = size
                    }
                    if self.sizer.pending == nil {
                        self.settleTask = nil
                        return
                    }
                }
            }
        }
    }
#endif
