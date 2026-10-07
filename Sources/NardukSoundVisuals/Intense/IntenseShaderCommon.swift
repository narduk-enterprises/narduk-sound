#if canImport(Metal)
    /// The MSL shared by the intense visualizers: the uniform block, the full-screen vertex, hashes, noise and the
    /// palette ramp. Compiled with the visualizers' own sources into one library by `IntenseRenderer`.
    enum IntenseShaderCommon {
        static let source = #"""
            #include <metal_stdlib>
            using namespace metal;

            // Must match IntenseUniforms in IntenseRenderer.swift (10 x float4).
            struct IntenseUniforms {
                float4 resTime;   // width, height, time (s), beats
                float4 env;       // kick, snare, hat, impact
                float4 wobble;    // cutoff, phase, energy, glitch
                float4 fx;        // flash (unused here), chroma, shakeX, shakeY
                float4 misc;      // wild, dropAmount, travel, barPhase
                float4 c0;
                float4 c1;
                float4 c2;
                float4 extra;     // limited flash (and laser strobe), unused, intensity (1, or less in calm), glitch amount
                float4 flashColor; // red-safe flash tint, a = 1 in calm
            };

            struct IntenseVertexOut {
                float4 position [[position]];
                float2 uv;
            };

            vertex IntenseVertexOut intenseVertex(uint vid [[vertex_id]]) {
                float2 p = float2(float((vid << 1) & 2), float(vid & 2));
                IntenseVertexOut out;
                out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
                out.uv = float2(p.x, 1.0 - p.y);
                return out;
            }

            static float hash11(float x) {
                x = fract(x * 0.1031);
                x *= x + 33.33;
                x *= x + x;
                return fract(x);
            }

            static float hash21(float2 p) {
                float3 p3 = fract(float3(p.xyx) * 0.1031);
                p3 += dot(p3, p3.yzx + 33.33);
                return fract((p3.x + p3.y) * p3.z);
            }

            static float vnoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                           mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), f.x), f.y);
            }

            static float fbm(float2 p) {
                float v = 0.0;
                float a = 0.5;
                for (int i = 0; i < 3; i++) {
                    v += a * vnoise(p);
                    p = p * 2.03 + float2(17.1, 9.2);
                    a *= 0.5;
                }
                return v;
            }

            static float bandAt(constant float *spectrum, float x) {
                float f = clamp(x, 0.0, 1.0) * 63.0;
                int i = int(f);
                int j = min(i + 1, 63);
                return mix(spectrum[i], spectrum[j], fract(f));
            }

            static float3 paletteAt(constant IntenseUniforms &u, float t) {
                float f = fract(t) * 3.0;
                float s = fract(f);
                s = s * s * (3.0 - 2.0 * s);
                if (f < 1.0) return mix(u.c0.rgb, u.c1.rgb, s);
                if (f < 2.0) return mix(u.c1.rgb, u.c2.rgb, s);
                return mix(u.c2.rgb, u.c0.rgb, s);
            }
            """#
    }
#endif
