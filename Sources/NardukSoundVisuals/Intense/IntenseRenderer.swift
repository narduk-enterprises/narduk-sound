#if canImport(Metal)
    import CoreGraphics
    import Metal

    /// Matches `IntenseUniforms` in `IntenseShaderCommon`: the tunnel's eight float4s, then two more, 160 bytes.
    struct IntenseUniforms {
        var base = WobbleTunnelUniforms()
        /// x: the rationed flash and laser strobe. y: 1 while a palette look is active, so a shader derives its fixed accents
        /// from the palette instead of using the classic ones. z: intensity (calm scales it down). w: glitch strength.
        var extra = SIMD4<Float>(repeating: 0)
        /// rgb: the red-safe flash tint. a: 1 in calm.
        var flashColor = SIMD4<Float>(1, 1, 1, 0)

        init() {}

        /// Writes `state`'s picture and `drive` into the uniforms. Touches no heap.
        @MainActor mutating func fill(size: CGSize, state: SoundVisualState, drive: IntenseDrive) {
            base.fill(size: size, state: state)
            extra = SIMD4(drive.flash, state.look.isNeutral ? 0 : 1, drive.intensity, drive.glitch)
            flashColor = SIMD4(drive.flashColor, state.calm ? 1 : 0)
        }
    }

    /// Device, queue and the pipelines of both intense visualizers. `shared` is built once for the system GPU; tests
    /// build their own. Returns nil when there is no Metal device or a shader does not compile.
    @MainActor
    final class IntenseRenderer {
        static let shared = IntenseRenderer()
        nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm

        let device: any MTLDevice
        let queue: any MTLCommandQueue
        private let hyperspace: any MTLRenderPipelineState
        private let fluid: any MTLRenderPipelineState
        private let glitch: any MTLRenderPipelineState
        private let fractal: any MTLRenderPipelineState
        private let synthwave: any MTLRenderPipelineState
        private let liquid: any MTLRenderPipelineState
        private let screenPass = MTLRenderPassDescriptor()
        private let fluidPass = MTLRenderPassDescriptor()

        init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            let source = [
                IntenseShaderCommon.source, IntenseEffects.source, HyperspaceShader.source, FluidGlitchShader.source,
                FractalDiveShader.source, SynthwaveShader.source, LiquidSplashShader.source,
            ].joined(separator: "\n")
            guard let device, let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: source, options: options),
                let vertex = library.makeFunction(name: "intenseVertex")
            else { return nil }
            func pipeline(_ name: String) -> (any MTLRenderPipelineState)? {
                guard let function = library.makeFunction(name: name) else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = function
                descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
                return try? device.makeRenderPipelineState(descriptor: descriptor)
            }
            guard let hyperspace = pipeline("hyperspaceFragment"), let fluid = pipeline("fluidFragment"),
                let glitch = pipeline("glitchFragment"),
                let fractal = pipeline("fractalDiveFragment"), let synthwave = pipeline("synthwaveFragment"),
                let liquid = pipeline("liquidSplashFragment")
            else { return nil }
            self.device = device
            self.queue = queue
            self.hyperspace = hyperspace
            self.fluid = fluid
            self.glitch = glitch
            self.fractal = fractal
            self.synthwave = synthwave
            self.liquid = liquid
        }

        /// Draws one frame of `kind` into `target` through `buffer`. `surface` is required for `.fluidGlitch`: the
        /// fluid pass reads last frame's texture and writes this frame's, and the glitch pass presents it.
        func encode(
            _ kind: IntenseKind, buffer: any MTLCommandBuffer, target: any MTLTexture, state: SoundVisualState,
            drive: IntenseDrive, uniforms: inout IntenseUniforms, surface: FeedbackSurface?,
            motion: IntenseMotion = IntenseMotion()
        ) {
            uniforms.fill(size: CGSize(width: target.width, height: target.height), state: state, drive: drive)
            switch kind {
            case .hyperspaceLasers:
                draw(hyperspace, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: nil)
            case .fractalDive:
                draw(fractal, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: nil, motion: motion)
            case .synthwaveFlyover:
                draw(
                    synthwave, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: nil,
                    motion: motion)
            case .liquidSplash:
                draw(liquid, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: nil)
            case .fluidGlitch:
                guard let surface else { return }
                if surface.isFresh {  // nothing to advect yet: start from black
                    let clear = fluidPass
                    clear.colorAttachments[0].texture = surface.read
                    clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    clear.colorAttachments[0].storeAction = .store
                    buffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                }
                draw(fluid, to: surface.write, buffer: buffer, state: state, uniforms: &uniforms, input: surface.read)
                draw(glitch, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: surface.write)
                surface.swap()
            }
        }

        private func draw(
            _ pipeline: any MTLRenderPipelineState, to target: any MTLTexture, buffer: any MTLCommandBuffer,
            state: SoundVisualState, uniforms: inout IntenseUniforms, input: (any MTLTexture)?,
            motion: IntenseMotion? = nil
        ) {
            let pass = screenPass
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            withUnsafeBytes(of: &uniforms) { bytes in
                if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 0) }
            }
            if let base = state.spectrum.baseAddress {
                encoder.setFragmentBytes(base, length: state.spectrum.count * MemoryLayout<Float>.stride, index: 1)
            }
            if let base = state.waveform.baseAddress {
                encoder.setFragmentBytes(base, length: state.waveform.count * MemoryLayout<Float>.stride, index: 2)
            }
            if let motion {
                var packed = motion.packed
                withUnsafeBytes(of: &packed) { bytes in
                    if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 3) }
                }
            }
            if let input { encoder.setFragmentTexture(input, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        /// Renders `frames` consecutive frames of `kind` offscreen (`advance` steps the state between them) and
        /// returns the last as `width * height * 4` BGRA bytes, or nil when the GPU cannot. `onFrame` sees each
        /// frame's mean luminance (0 ... 1), so a test can watch the flash over time.
        func renderOffscreen(
            _ kind: IntenseKind, state: SoundVisualState, width: Int, height: Int, frames: Int = 1,
            limiter: inout IntenseFlashLimiter, advance: (() -> Void)? = nil,
            onFrame: ((Float, IntenseDrive) -> Void)? = nil
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
            let surface = kind == .fluidGlitch ? FeedbackSurface(device: device, width: width, height: height) : nil
            if kind == .fluidGlitch, surface == nil { return nil }
            var uniforms = IntenseUniforms()
            var motion = IntenseMotion()
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for index in 0..<max(frames, 1) {
                guard let buffer = queue.makeCommandBuffer() else { return nil }
                let drive = IntenseDrive(state: state, limiter: &limiter)
                motion.advance(kind, state: state, intensity: drive.intensity)
                encode(
                    kind, buffer: buffer, target: texture, state: state, drive: drive, uniforms: &uniforms,
                    surface: surface, motion: motion)
                #if os(macOS)
                    if !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
                        blit.synchronize(resource: texture)
                        blit.endEncoding()
                    }
                #endif
                buffer.commit()
                buffer.waitUntilCompleted()
                guard buffer.status == .completed else { return nil }
                if let onFrame {
                    texture.getBytes(
                        &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                    var sum = 0
                    var i = 0
                    while i < pixels.count {
                        sum += Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                        i += 4
                    }
                    onFrame(Float(sum) / Float(width * height * 3 * 255), drive)
                }
                if index < max(frames, 1) - 1 { advance?() }
            }
            texture.getBytes(
                &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }
    }
#endif
