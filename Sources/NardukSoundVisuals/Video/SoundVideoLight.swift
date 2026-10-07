#if canImport(Metal)
    import CoreGraphics
    import Metal

    /// One light the video exporter can draw: any of the library's Metal visualizers.
    public enum SoundVideoLight: Sendable, Hashable {
        case intense(IntenseKind)
        case shaderPack(ShaderPackKind)
        case tunnel
    }

    /// Draws `SoundVideoLight`s into any texture, frame after frame, with the per-light state the live views keep
    /// (the flash limiter, the dive and flyover motion, the feedback textures). The same encoders the live views call
    /// draw here, so a video frame is the picture the screen would show for the same `SoundVisualState`.
    @MainActor
    final class SoundVideoPainter {
        let device: any MTLDevice
        let queue: any MTLCommandQueue
        private var light: SoundVideoLight?
        private var limiter = IntenseFlashLimiter()
        private var motion = IntenseMotion()
        private var intenseUniforms = IntenseUniforms()
        private var tunnelUniforms = WobbleTunnelUniforms()
        private var surface: FeedbackSurface?
        private let tunnelPass = MTLRenderPassDescriptor()

        init?() {
            guard let intense = IntenseRenderer.shared else { return nil }
            device = intense.device
            queue = intense.queue
        }

        /// Encodes one frame of `light` for `state` into `target`. False when the light cannot draw on this GPU.
        @discardableResult
        func encode(
            _ light: SoundVideoLight, buffer: any MTLCommandBuffer, target: any MTLTexture, state: SoundVisualState
        ) -> Bool {
            if light != self.light {
                // A new light starts from scratch, like a new tile on screen.
                self.light = light
                limiter = IntenseFlashLimiter()
                motion = IntenseMotion()
                surface = nil
            }
            switch light {
            case .intense(let kind):
                guard let renderer = IntenseRenderer.shared else { return false }
                if kind.usesFeedback, !ensureSurface(width: target.width, height: target.height) { return false }
                let drive = IntenseDrive(state: state, limiter: &limiter)
                motion.advance(kind, state: state, intensity: drive.intensity)
                renderer.encode(
                    kind, buffer: buffer, target: target, state: state, drive: drive, uniforms: &intenseUniforms,
                    surface: surface, motion: motion)
            case .shaderPack(let kind):
                guard let renderer = ShaderPackRenderer.shared else { return false }
                if kind == .feedback, !ensureSurface(width: target.width, height: target.height) { return false }
                renderer.encode(
                    kind, buffer: buffer, target: target, state: state, calm: state.calm,
                    uniforms: &tunnelUniforms, surface: surface)
            case .tunnel:
                guard let renderer = WobbleTunnelRenderer.shared else { return false }
                let pass = tunnelPass
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                pass.colorAttachments[0].storeAction = .store
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
                renderer.encode(
                    into: encoder, size: CGSize(width: target.width, height: target.height), state: state,
                    uniforms: &tunnelUniforms)
                encoder.endEncoding()
            }
            return true
        }

        private func ensureSurface(width: Int, height: Int) -> Bool {
            if surface == nil || surface?.width != width || surface?.height != height {
                surface = FeedbackSurface(device: device, width: width, height: height)
            }
            return surface != nil
        }
    }
#endif
