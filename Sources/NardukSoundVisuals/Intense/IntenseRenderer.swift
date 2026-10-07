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

    /// What a plugin tile draws through: a mipmapped scene texture, and the one pixel its last mip reduces to.
    final class WatchedSurface {
        let width: Int
        let height: Int
        let scene: any MTLTexture
        let readback: any MTLBuffer

        init?(device: any MTLDevice, width: Int, height: Int) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: IntenseRenderer.pixelFormat, width: max(width, 1), height: max(height, 1), mipmapped: true)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let scene = device.makeTexture(descriptor: descriptor),
                let readback = device.makeBuffer(length: 4, options: .storageModeShared)
            else { return nil }
            self.width = descriptor.width
            self.height = descriptor.height
            self.scene = scene
            self.readback = readback
        }

        /// The mean luma (0 ... 1) of the last frame whose buffer has completed.
        var luma: Float {
            let bytes = readback.contents().assumingMemoryBound(to: UInt8.self)
            return (Float(bytes[0]) + Float(bytes[1]) + Float(bytes[2])) / (3 * 255)
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
        /// Draws a finished picture scaled by a gain (the watchdog's dim). Buffer 0 holds the gain.
        static let dimSource = #"""
            fragment float4 intenseDimFragment(
                IntenseVertexOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                constant float &gain [[buffer(0)]]) {
                constexpr sampler s(filter::nearest, address::clamp_to_edge);
                float4 c = scene.sample(s, in.uv);
                return float4(c.rgb * gain, 1.0);
            }
            """#

        /// Built-in pipelines by fragment name; plugin pipelines by `pluginKey`.
        private var pipelines: [String: any MTLRenderPipelineState] = [:]
        /// The compile error of a plugin that failed, by `pluginKey`, so its tile can show it.
        private var pluginErrors: [String: String] = [:]
        private let dimPipeline: any MTLRenderPipelineState
        private let options: MTLCompileOptions
        private let prelude: String
        private let screenPass = MTLRenderPassDescriptor()
        private let fluidPass = MTLRenderPassDescriptor()
        /// What the Canvas ports read beyond the spectrum and waveform; filled in place each frame.
        private var aux: IntenseAux

        init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            let shared = [IntenseShaderCommon.source, IntenseEffects.source].joined(separator: "\n")
            let source = [
                shared, HyperspaceShader.source, FluidGlitchShader.source, FractalDiveShader.source,
                SynthwaveShader.source, LiquidSplashShader.source, SunShader.source, SpectrumMetalShader.source,
                VortexMetalShader.source, HaloMetalShader.source, ScopeMetalShader.source,
                WobbleMeterMetalShader.source,
                PadsMetalShader.source, MirrorMetalShader.source, PhosphorMetalShader.source,
                PianoRollMetalShader.source, PitchWheelMetalShader.source, AudioTerrainMetalShader.source,
                ParticleFieldMetalShader.source, KaleidoscopeMetalShader.source,
                Self.dimSource,
            ].joined(separator: "\n")
            guard let device, let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: source, options: options)
            else { return nil }
            self.device = device
            self.queue = queue
            self.aux = IntenseAux(device: device)
            self.options = options
            self.prelude = shared
            guard let dim = try? Self.makePipeline(device: device, library: library, fragment: "intenseDimFragment")
            else { return nil }
            dimPipeline = dim
            for kind in IntenseKind.allCases {
                for name in [kind.fragment] + (kind.feedbackFragment.map { [$0] } ?? []) where pipelines[name] == nil {
                    guard let pipeline = try? Self.makePipeline(device: device, library: library, fragment: name)
                    else { return nil }
                    pipelines[name] = pipeline
                }
            }
        }

        private static func makePipeline(
            device: any MTLDevice, library: any MTLLibrary, fragment: String
        ) throws -> any MTLRenderPipelineState {
            guard let vertex = library.makeFunction(name: "intenseVertex"),
                let function = library.makeFunction(name: fragment)
            else { throw IntensePluginError.missingFunction(fragment) }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = function
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        /// The key a plugin's pipeline is cached under: its id and a hash of its source, so an edit recompiles.
        private func pluginKey(_ kind: IntenseKind) -> String {
            "\(kind.id)#\(kind.pluginSource.map { Self.stableHash($0) } ?? 0)"
        }

        /// FNV-1a over the UTF-8 bytes (`hashValue` is seeded per process).
        private static func stableHash(_ text: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            return hash
        }

        /// Compiles `kind`'s plugin source (after the shared library) unless it already is, and returns its compile
        /// error text, or nil when it is ready to draw. A built-in is always ready. The compile runs on the caller's
        /// thread: call it when a file changes, not per frame.
        @discardableResult
        func prepare(_ kind: IntenseKind) -> String? {
            guard let source = kind.pluginSource else { return nil }
            let key = pluginKey(kind)
            if pipelines[key] != nil { return nil }
            if let known = pluginErrors[key] { return known }
            do {
                let library = try device.makeLibrary(source: prelude + "\n" + source, options: options)
                pipelines[key] = try Self.makePipeline(device: device, library: library, fragment: kind.fragment)
                return nil
            } catch {
                let text = IntensePluginError.describe(error, fragment: kind.fragment)
                pluginErrors[key] = text
                return text
            }
        }

        /// Forgets the plugin pipelines and errors that are not for one of `kinds` (after a reload), so a long
        /// editing session does not hold every old version.
        func retainPlugins(_ kinds: [IntenseKind]) {
            let keep = Set(kinds.map { pluginKey($0) })
            pipelines = pipelines.filter { !$0.key.contains("#") || keep.contains($0.key) }
            pluginErrors = pluginErrors.filter { keep.contains($0.key) }
        }

        private func pipeline(for kind: IntenseKind) -> (any MTLRenderPipelineState)? {
            if kind.isPlugin {
                prepare(kind)
                return pipelines[pluginKey(kind)]
            }
            return pipelines[kind.fragment]
        }

        /// Draws one frame of `kind` into `target` through `buffer`. `surface` is required for `.fluidGlitch`: the
        /// fluid pass reads last frame's texture and writes this frame's, and the glitch pass presents it. A plugin
        /// that did not compile draws nothing (its tile shows the error).
        func encode(
            _ kind: IntenseKind, buffer: any MTLCommandBuffer, target: any MTLTexture, state: SoundVisualState,
            drive: IntenseDrive, uniforms: inout IntenseUniforms, surface: FeedbackSurface?,
            motion: IntenseMotion = IntenseMotion()
        ) {
            uniforms.fill(size: CGSize(width: target.width, height: target.height), state: state, drive: drive)
            guard let main = pipeline(for: kind) else { return }
            let needs = kind.auxNeeds
            if !needs.isEmpty { aux.fill(from: state, needs: needs) }
            if let feedback = kind.feedbackFragment {
                guard let surface, let fluid = pipelines[feedback] else { return }
                if surface.isFresh {  // nothing to advect yet: start from black
                    let clear = fluidPass
                    clear.colorAttachments[0].texture = surface.read
                    clear.colorAttachments[0].loadAction = .clear
                    clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    clear.colorAttachments[0].storeAction = .store
                    buffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
                }
                draw(fluid, to: surface.write, buffer: buffer, state: state, uniforms: &uniforms, input: surface.read)
                draw(main, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: surface.write)
                surface.swap()
            } else {
                draw(
                    main, to: target, buffer: buffer, state: state, uniforms: &uniforms, input: nil, motion: motion,
                    needs: needs)
            }
        }

        /// Like `encode`, for a plugin: draws into `surface`'s scene texture, reduces it to one pixel for the watchdog
        /// (`surface.readback`, read once the buffer completes), then copies it to `target` scaled by `gain`.
        func encodeWatched(
            _ kind: IntenseKind, buffer: any MTLCommandBuffer, target: any MTLTexture, state: SoundVisualState,
            drive: IntenseDrive, uniforms: inout IntenseUniforms, motion: IntenseMotion, surface: WatchedSurface,
            gain: Float
        ) {
            encode(
                kind, buffer: buffer, target: surface.scene, state: state, drive: drive, uniforms: &uniforms,
                surface: nil, motion: motion)
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: surface.scene)
                blit.copy(
                    from: surface.scene, sourceSlice: 0, sourceLevel: surface.scene.mipmapLevelCount - 1,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                    to: surface.readback, destinationOffset: 0, destinationBytesPerRow: 4, destinationBytesPerImage: 4)
                blit.endEncoding()
            }
            let pass = screenPass
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(dimPipeline)
            var gain = gain
            encoder.setFragmentBytes(&gain, length: MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(surface.scene, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        private func draw(
            _ pipeline: any MTLRenderPipelineState, to target: any MTLTexture, buffer: any MTLCommandBuffer,
            state: SoundVisualState, uniforms: inout IntenseUniforms, input: (any MTLTexture)?,
            motion: IntenseMotion? = nil, needs: IntenseAux.Needs = []
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
            if !needs.isEmpty { aux.bind(needs, to: encoder) }
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
            let surface = kind.usesFeedback ? FeedbackSurface(device: device, width: width, height: height) : nil
            if kind.usesFeedback, surface == nil { return nil }
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
