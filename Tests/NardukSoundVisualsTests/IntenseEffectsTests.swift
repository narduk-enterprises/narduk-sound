#if canImport(Metal)
    import Foundation
    import Metal
    import Testing

    @testable import NardukSoundVisuals

    /// The shared Metal effects library (narduk-libs #1656). A probe kernel compiled from the common MSL, the
    /// library and a kernel that calls every helper writes its results to a buffer, so each helper's contract is
    /// checked on the GPU it will run on.
    @Suite struct IntenseEffectsTests {
        nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

        static let probeCount = 24

        static let probe = #"""
            kernel void fxProbe(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) {
                if (id != 0) return;
                float3 light = fxKeyLight();
                out[0] = fxNoise3(float3(0.3, 7.1, 2.9));
                out[1] = fxNoise3(float3(0.3, 7.1, 2.9));
                out[2] = fxFbm3(float3(1.2, 3.4, 5.6), 3);
                out[3] = fxFbm3(float3(9.9, -3.4, 0.6), 5);
                out[4] = fxRidge(0.5, 0.8);
                out[5] = fxRidge(0.05, 0.8);
                out[6] = fxRidge(0.45, 0.8);
                float3 flat = fxNormal(0.4, 0.4, 0.4, 0.01, 5.0);
                out[7] = flat.z;
                float3 tilted = fxNormal(0.4, 0.5, 0.4, 0.01, 5.0);
                out[8] = tilted.x;
                float2 lit = fxLight(float3(0.0, 0.0, 1.0), float3(0.0, 0.0, 1.0), 28.0);
                out[9] = lit.x;
                out[10] = lit.y;
                float2 away = fxLight(float3(0.0, 0.0, 1.0), float3(0.0, 0.0, -1.0), 28.0);
                out[11] = away.x;
                out[12] = fxBall(float2(2.0, 0.0), light, float3(1.0)).x;
                out[13] = fxBall(float2(-0.2, 0.3), light, float3(1.0)).x;
                out[14] = fxZoomLayer(float2(0.5, 0.5), 0.0).fade;
                out[15] = fxZoomLayer(float2(0.5, 0.5), 1.0).fade;
                out[16] = fxZoomLayer(float2(0.5, 0.5), 0.5).fade;
                out[17] = fxZoomLayer(float2(0.5, 0.5), 1.0).scale;
                float2 c; float h;
                bool hit = fxCell(float2(0.3, 0.3), 0.2, 1.0, 1.0, c, h);
                out[18] = hit ? 1.0 : 0.0;
                out[19] = length(c - float2(0.3, 0.3)) < 0.2 ? 1.0 : 0.0;
                out[20] = fxTonemap(float3(6.0), 1.4).x;
                out[21] = fxTonemap(float3(0.0), 1.4).x;
                out[22] = fxVignette(float3(1.0), float2(1.0, 0.0), 0.09).x;
                out[23] = fxCylinder(float2(0.5, 0.0), 2.0, 10.0, 0.35).z - fxCylinder(float2(0.5, 0.0), 2.0, 0.0, 0.35).z;
            }
            """#

        static func runProbe() throws -> [Float] {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let options = MTLCompileOptions()
            let source = [IntenseShaderCommon.source, IntenseEffects.source, probe].joined(separator: "\n")
            let library = try device.makeLibrary(source: source, options: options)
            let function = try #require(library.makeFunction(name: "fxProbe"))
            let pipeline = try device.makeComputePipelineState(function: function)
            let buffer = try #require(
                device.makeBuffer(length: probeCount * MemoryLayout<Float>.stride, options: .storageModeShared))
            let queue = try #require(device.makeCommandQueue())
            let command = try #require(queue.makeCommandBuffer())
            let encoder = try #require(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            let pointer = buffer.contents().bindMemory(to: Float.self, capacity: probeCount)
            return Array(UnsafeBufferPointer(start: pointer, count: probeCount))
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"))
        func everyHelperCompilesAndKeepsItsContract() throws {
            let v = try Self.runProbe()
            // Noise: in range and deterministic.
            #expect(v[0] >= 0 && v[0] <= 1)
            #expect(v[0] == v[1])
            #expect(v[2] >= 0 && v[2] <= 1)
            #expect(v[3] >= 0 && v[3] <= 1)
            // Ridge: 1 at the crest, 0 outside the thin band, between in between.
            #expect(abs(v[4] - 1) < 1e-4)
            #expect(v[5] == 0)
            #expect(v[6] > 0 && v[6] < 1)
            // Normals: a flat field faces the viewer; a field rising in x tilts the normal toward -x.
            #expect(abs(v[7] - 1) < 1e-4)
            #expect(v[8] < 0)
            // Lighting: lit head on is the full diffuse and a full specular; lit from behind only the ambient floor.
            #expect(abs(v[9] - 1) < 1e-4)
            #expect(abs(v[10] - 1) < 1e-4)
            #expect(abs(v[11] - 0.35) < 1e-4)
            // A ball draws nothing outside its radius and something inside.
            #expect(v[12] == 0)
            #expect(v[13] > 0)
            // A zoom layer fades to zero at both ends of the cycle, is full in the middle, and doubles across it.
            #expect(abs(v[14]) < 1e-4)
            #expect(abs(v[15]) < 1e-4)
            #expect(abs(v[16] - 1) < 1e-4)
            #expect(abs(v[17] - 2) < 1e-4)
            // A cell at full density always holds something, centred inside its own cell.
            #expect(v[18] == 1)
            #expect(v[19] == 1)
            // The tone map compresses bright light under 1 and keeps black black; the vignette darkens the edge.
            #expect(v[20] < 1 && v[20] > 0.99)
            #expect(v[21] == 0)
            #expect(abs(v[22] - 0.91) < 1e-4)
            // Travel streams the cylinder field outward (the sample slides along the axis).
            #expect(v[23] < 0)
        }
    }
#endif
