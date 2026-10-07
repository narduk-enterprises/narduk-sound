#if canImport(Metal)
    import CoreGraphics
    import Metal

    /// The pack's shaders. `feedback` carries state between frames; the others are pure functions of the uniforms.
    public enum ShaderPackKind: String, Sendable, CaseIterable, Hashable {
        case plasma, warpGrid, starfield, feedback
        /// Glossy liquid metaballs in a dark studio.
        case bassBlobs
        /// Folding aurora curtains over a dark horizon.
        case aurora
        /// "Aurora waves": silky multi-strand ribbons with an embedded equaliser over a reflecting sea.
        case auroraWaves
        /// A glowing wireframe draped over two swells and a trough.
        case meshWave
        /// A solar limb erupting flares and prominences on the beat.
        case solarFlare
        /// The side-view sea: rolling swells that break on the beat.
        case oceanWaves
        /// Shells over a night sky: the kick launches them, the bass sets their size, a drop fires a finale.
        case fireworks

        /// The name the gallery shows.
        public var title: String {
            switch self {
            case .plasma: "Plasma"
            case .warpGrid: "Warp grid"
            case .starfield: "Starfield"
            case .feedback: "Feedback"
            case .bassBlobs: "Bass blobs"
            case .aurora: "Aurora curtains"
            case .auroraWaves: "Aurora waves"
            case .meshWave: "Mesh wave"
            case .solarFlare: "Solar flare"
            case .oceanWaves: "Ocean waves"
            case .fireworks: "Fireworks"
            }
        }

        var fragmentName: String {
            switch self {
            case .plasma: "plasmaFragment"
            case .warpGrid: "warpGridFragment"
            case .starfield: "starfieldFragment"
            case .feedback: "feedbackFragment"
            case .bassBlobs: "bassBlobsFragment"
            case .aurora: "auroraFragment"
            case .auroraWaves: "auroraWavesFragment"
            case .meshWave: "meshWaveFragment"
            case .solarFlare: "solarFlareFragment"
            case .oceanWaves: "oceanWavesFragment"
            case .fireworks: "fireworksFragment"
            }
        }
    }

    /// The previous frame for the feedback shader: two textures at the drawable's size that swap roles each frame.
    /// Built once per size (a resize rebuilds it), never per frame.
    final class FeedbackSurface {
        let width: Int
        let height: Int
        private var textures: [any MTLTexture]
        private var readIndex = 0
        private(set) var isFresh = true

        init?(device: any MTLDevice, width: Int, height: Int) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: ShaderPackRenderer.pixelFormat, width: max(width, 1), height: max(height, 1),
                mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let a = device.makeTexture(descriptor: descriptor), let b = device.makeTexture(descriptor: descriptor)
            else { return nil }
            self.width = descriptor.width
            self.height = descriptor.height
            textures = [a, b]
        }

        var read: any MTLTexture { textures[readIndex] }
        var write: any MTLTexture { textures[1 - readIndex] }

        func swap() {
            readIndex = 1 - readIndex
            isFresh = false
        }
    }

    /// Device, queue and one pipeline per shader. `shared` is built once for the system GPU; tests build their own.
    /// Returns nil when there is no Metal device or the source does not compile.
    @MainActor
    final class ShaderPackRenderer {
        static let shared = ShaderPackRenderer()
        nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm

        let device: any MTLDevice
        let queue: any MTLCommandQueue
        private let pipelines: [ShaderPackKind: any MTLRenderPipelineState]
        private let presentPipeline: any MTLRenderPipelineState
        private let screenPass = MTLRenderPassDescriptor()
        private let feedbackPass = MTLRenderPassDescriptor()

        init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            guard let device, let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: ShaderPackSource.source, options: options),
                let vertex = library.makeFunction(name: "packVertex"),
                let presentFunction = library.makeFunction(name: "presentFragment")
            else { return nil }
            func pipeline(_ fragment: any MTLFunction) -> (any MTLRenderPipelineState)? {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
                return try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            var built: [ShaderPackKind: any MTLRenderPipelineState] = [:]
            for kind in ShaderPackKind.allCases {
                guard let function = library.makeFunction(name: kind.fragmentName), let state = pipeline(function)
                else { return nil }
                built[kind] = state
            }
            guard let present = pipeline(presentFunction) else { return nil }
            self.device = device
            self.queue = queue
            pipelines = built
            presentPipeline = present
        }

        /// Draws one frame of `kind` for `state` into `target` through `buffer`. `surface` is required for
        /// `.feedback` (and ignored otherwise): the shader reads last frame's texture, writes this frame's, and
        /// presents the result to `target`.
        func encode(
            _ kind: ShaderPackKind, buffer: any MTLCommandBuffer, target: any MTLTexture, state: SoundVisualState,
            calm: Bool, uniforms: inout WobbleTunnelUniforms, surface: FeedbackSurface?
        ) {
            uniforms.fill(size: CGSize(width: target.width, height: target.height), state: state)
            uniforms.fx.x = calm ? 1 : 0
            if kind == .feedback, let surface {
                if surface.isFresh {  // nothing to feed back yet: start from black
                    let clear = feedbackPass
                    clear.colorAttachments[0].texture = surface.read
                    clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    clear.colorAttachments[0].storeAction = .store
                    buffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                }
                let pass = feedbackPass
                pass.colorAttachments[0].texture = surface.write
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass), let pipeline = pipelines[kind] {
                    encoder.setRenderPipelineState(pipeline)
                    bind(encoder, uniforms: &uniforms, state: state)
                    encoder.setFragmentTexture(surface.read, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }
                let screen = screenPass
                screen.colorAttachments[0].texture = target
                screen.colorAttachments[0].loadAction = .dontCare
                screen.colorAttachments[0].storeAction = .store
                if let encoder = buffer.makeRenderCommandEncoder(descriptor: screen) {
                    encoder.setRenderPipelineState(presentPipeline)
                    encoder.setFragmentTexture(surface.write, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }
                surface.swap()
            } else if let pipeline = pipelines[kind] {
                let screen = screenPass
                screen.colorAttachments[0].texture = target
                screen.colorAttachments[0].loadAction = .dontCare
                screen.colorAttachments[0].storeAction = .store
                guard let encoder = buffer.makeRenderCommandEncoder(descriptor: screen) else { return }
                encoder.setRenderPipelineState(pipeline)
                bind(encoder, uniforms: &uniforms, state: state)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }

        private func bind(
            _ encoder: any MTLRenderCommandEncoder, uniforms: inout WobbleTunnelUniforms, state: SoundVisualState
        ) {
            withUnsafeBytes(of: &uniforms) { bytes in
                if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 0) }
            }
            if let base = state.spectrum.baseAddress {
                encoder.setFragmentBytes(base, length: state.spectrum.count * MemoryLayout<Float>.stride, index: 1)
            }
            if let base = state.waveform.baseAddress {
                encoder.setFragmentBytes(base, length: state.waveform.count * MemoryLayout<Float>.stride, index: 2)
            }
        }

        /// Renders `frames` consecutive frames of `kind` (the state is advanced by the caller between them via
        /// `advance`) offscreen and returns the last as `width * height * 4` BGRA bytes, or nil when the GPU cannot.
        /// For golden-image tests.
        func renderOffscreen(
            _ kind: ShaderPackKind, state: SoundVisualState, width: Int, height: Int, frames: Int = 1,
            calm: Bool = false, advance: (() -> Void)? = nil
        ) -> [UInt8]? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            #if os(macOS)
                descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            #else
                descriptor.storageMode = .shared
            #endif
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let surface = kind == .feedback ? FeedbackSurface(device: device, width: width, height: height) : nil
            if kind == .feedback, surface == nil { return nil }
            var uniforms = WobbleTunnelUniforms()
            for index in 0..<max(frames, 1) {
                guard let buffer = queue.makeCommandBuffer() else { return nil }
                encode(
                    kind, buffer: buffer, target: texture, state: state, calm: calm, uniforms: &uniforms,
                    surface: surface)
                #if os(macOS)
                    if index == max(frames, 1) - 1, !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder()
                    {
                        blit.synchronize(resource: texture)
                        blit.endEncoding()
                    }
                #endif
                buffer.commit()
                buffer.waitUntilCompleted()
                guard buffer.status == .completed else { return nil }
                advance?()
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(
                &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }
    }
#endif
