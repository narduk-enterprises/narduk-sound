#if canImport(Metal)
    import Metal

    /// The exporter's render-scale governor. Each light draws its first frames at full size while their GPU time is
    /// measured; a light over the budget then draws at a smaller scale (never under half) into an offscreen texture
    /// that is scaled up into the video frame. The live screen's `SoundRenderGovernor` makes the same trade, so a heavy
    /// light looks in the video as it looked on a slower screen, and a kid waits about as long as the song.
    @MainActor
    final class SoundVideoScaler {
        /// Frames timed before a light's scale is settled; the first two are left out (shader warm-up).
        static let measuredFrames = 12
        static let warmUpFrames = 2
        static let lowest = 0.5

        private let device: any MTLDevice
        private let width: Int
        private let height: Int
        private let budget: Double?
        private var scales: [SoundVideoLight: Double] = [:]
        private var timings: [SoundVideoLight: [Double]] = [:]
        private var small: (scale: Double, texture: any MTLTexture)?
        private var pipeline: (any MTLRenderPipelineState)?
        private let pass = MTLRenderPassDescriptor()
        private(set) var lowestScale = 1.0

        init(device: any MTLDevice, width: Int, height: Int, budgetMilliseconds: Double?) {
            self.device = device
            self.width = width
            self.height = height
            budget = budgetMilliseconds
        }

        /// The scale `light` draws at now: 1 until it is measured, then whatever fits the budget.
        func scale(for light: SoundVideoLight) -> Double {
            scales[light] ?? 1
        }

        /// Records one full-size frame's GPU time; after enough of them, settles the light's scale.
        func record(_ light: SoundVideoLight, milliseconds: Double) {
            guard let budget, scales[light] == nil, milliseconds > 0 else { return }
            var times = timings[light, default: []]
            times.append(milliseconds)
            guard times.count >= Self.measuredFrames else {
                timings[light] = times
                return
            }
            timings[light] = nil
            let measured = times.dropFirst(Self.warmUpFrames).sorted()
            let median = measured[measured.count / 2]
            // Cost follows the pixel count, so the side scales by the square root, rounded down to a twentieth.
            let fit = median <= budget ? 1 : (Self.lowest...1).clamp((budget / median).squareRoot())
            let scale = fit >= 1 ? 1 : max(Self.lowest, (fit * 20).rounded(.down) / 20)
            scales[light] = scale
            lowestScale = min(lowestScale, scale)
        }

        /// The offscreen texture for `scale` (kept while the scale holds).
        func texture(scale: Double) -> (any MTLTexture)? {
            if let small, small.scale == scale { return small.texture }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: IntenseRenderer.pixelFormat, width: max(2, Int(Double(width) * scale) & ~1),
                height: max(2, Int(Double(height) * scale) & ~1), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            small = (scale, texture)
            return texture
        }

        /// Draws `source` over all of `target`, filtered.
        func encodeUpscale(from source: any MTLTexture, to target: any MTLTexture, buffer: any MTLCommandBuffer) {
            guard let pipeline = pipeline ?? makePipeline() else { return }
            self.pipeline = pipeline
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        private func makePipeline() -> (any MTLRenderPipelineState)? {
            guard let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "soundVideoUpscaleVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "soundVideoUpscaleFragment")
            descriptor.colorAttachments[0].pixelFormat = IntenseRenderer.pixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        static let source = """
            #include <metal_stdlib>
            using namespace metal;

            struct UpscaleOut { float4 position [[position]]; float2 uv; };

            vertex UpscaleOut soundVideoUpscaleVertex(uint id [[vertex_id]]) {
                float2 uv = float2((id << 1) & 2, id & 2);
                UpscaleOut out;
                out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
                out.uv = uv;
                return out;
            }

            fragment float4 soundVideoUpscaleFragment(UpscaleOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
                constexpr sampler linear(filter::linear, address::clamp_to_edge);
                return source.sample(linear, in.uv);
            }
            """
    }

    extension ClosedRange where Bound == Double {
        fileprivate func clamp(_ value: Double) -> Double { Swift.min(upperBound, Swift.max(lowerBound, value)) }
    }
#endif
