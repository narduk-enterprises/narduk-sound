#if canImport(Metal)
    import CoreGraphics
    import Metal

    /// Matches `TunnelUniforms` in `WobbleTunnelShader`: eight float4s, no padding surprises.
    struct WobbleTunnelUniforms {
        var resTime = SIMD4<Float>(repeating: 0)
        var env = SIMD4<Float>(repeating: 0)
        var wobble = SIMD4<Float>(repeating: 0)
        var fx = SIMD4<Float>(repeating: 0)
        var misc = SIMD4<Float>(repeating: 0)
        var c0 = SIMD4<Float>(repeating: 0)
        var c1 = SIMD4<Float>(repeating: 0)
        var c2 = SIMD4<Float>(repeating: 0)

        init() {}

        /// Writes `state`'s current picture into the uniforms. Touches no heap: it only reads the state's fields.
        @MainActor mutating func fill(size: CGSize, state: SoundVisualState) {
            let palette = state.palette
            resTime = SIMD4(
                Float(size.width), Float(size.height),
                Float(state.time.truncatingRemainder(dividingBy: 3600)),
                Float(state.beats.truncatingRemainder(dividingBy: 4096)))
            env = SIMD4(state.kick, state.snare, state.hat, state.impact)
            wobble = SIMD4(state.wobbleCutoff, state.wobblePhase, state.energy, state.glitch)
            fx = SIMD4(state.flash, state.chroma, state.shakeOffset.x, state.shakeOffset.y)
            misc = SIMD4(
                state.wild, state.dropAmount, Float(state.travel.truncatingRemainder(dividingBy: 4096)),
                state.barPhase)
            c0 = SIMD4(palette.c0, 1)
            c1 = SIMD4(palette.c1, 1)
            c2 = SIMD4(palette.c2, 1)
        }
    }

    /// The tunnel's device, queue and pipeline. `shared` is built once for the system GPU; tests build their own
    /// from a given device. Returns nil when there is no Metal device or the shader does not compile.
    @MainActor
    final class WobbleTunnelRenderer {
        static let shared = WobbleTunnelRenderer()
        static let pixelFormat = MTLPixelFormat.bgra8Unorm

        let device: any MTLDevice
        let queue: any MTLCommandQueue
        let pipeline: any MTLRenderPipelineState

        init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            guard let device, let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: WobbleTunnelShader.source, options: options),
                let vertex = library.makeFunction(name: "tunnelVertex"),
                let fragment = library.makeFunction(name: "tunnelFragment")
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
        }

        /// Encodes one full-screen tunnel pass for `state`'s current picture. The live view and the offscreen
        /// renderer both call this, so a golden image shows exactly what the screen draws. Allocates nothing: the
        /// uniforms are the caller's, and the spectrum and waveform go to the GPU straight from the state's buffers.
        func encode(
            into encoder: any MTLRenderCommandEncoder, size: CGSize, state: SoundVisualState,
            uniforms: inout WobbleTunnelUniforms
        ) {
            uniforms.fill(size: size, state: state)
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
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        /// Renders `state`'s current picture offscreen and returns it as `width * height * 4` BGRA bytes, or nil when
        /// the GPU cannot do it. For golden-image tests.
        func renderOffscreen(state: SoundVisualState, width: Int, height: Int) -> [UInt8]? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            #if os(macOS)
                descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            #else
                descriptor.storageMode = .shared
            #endif
            guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer()
            else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            var uniforms = WobbleTunnelUniforms()
            encode(into: encoder, size: CGSize(width: width, height: height), state: state, uniforms: &uniforms)
            encoder.endEncoding()
            #if os(macOS)
                if !device.hasUnifiedMemory, let blit = buffer.makeBlitCommandEncoder() {
                    blit.synchronize(resource: texture)
                    blit.endEncoding()
                }
            #endif
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(
                &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return pixels
        }
    }
#endif
