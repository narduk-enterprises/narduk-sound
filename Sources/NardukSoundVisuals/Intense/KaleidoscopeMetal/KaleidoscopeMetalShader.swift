#if canImport(Metal)
    /// Beat kaleidoscope (Metal): a beat tunnel seen through a kaleidoscope. Concentric rings rush out of the center
    /// on the beat clock (`travel`); the 64-band spectrum is folded into mirrored petals around them, six folds at
    /// rest and eight in a drop, spinning with the wildness. Calm keeps the folds and stops the spin. The Metal port
    /// of the Canvas `BeatKaleidoscopeView` (the snare ratchet of the old view is replaced by the continuous spin).
    enum KaleidoscopeMetalShader {
        static let source = #"""
            // The folded spectrum's reach at angle `a` (radians, already spun): the petal's radius, or -1 between petals.
            static float kaleidoscopeMetalReach(constant float *spectrum, float a, float wedge) {
                float period = wedge * 2.0;
                float m = a - floor(a / period) * period;
                if (m >= wedge) return -1.0;
                float s = m / wedge;
                float t = 1.0 - abs(2.0 * s - 1.0);
                return 0.14 + 0.7 * bandAt(spectrum, t);
            }

            fragment float4 kaleidoscopeMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z;
                float kick = u.env.x;
                float energy = u.wobble.z;
                float wild = u.misc.x;
                float drop = u.misc.y;
                float travel = fract(u.misc.z);
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float r = length(p);
                float3 col = float3(0.0);

                // The tunnel: nine rings, each born at the center and growing to the edge.
                for (int i = 0; i < 9; i++) {
                    float phase = (float(i) + travel) / 9.0;
                    float radius = 1.15 * phase * phase;
                    float width = max(0.004, 0.01 * (0.4 + phase));
                    float pulse = min(1.0 + kick * 0.6 * (1.0 - phase), 1.4);
                    float alpha = (0.15 + 0.6 * phase) * pulse;
                    col += paletteAt(u, phase * 0.5 + 0.1) * alpha * smoothstep(width * 1.4, width * 0.3, abs(r - radius));
                }

                // The fold: petals of mirrored spectrum. Calm (intensity below 1) holds the spin still.
                float folds = drop > 0.5 ? 8.0 : 6.0;
                float wedge = 6.2831853 / folds;
                float spin = intensity < 1.0 ? 0.0 : time * 0.12 * (0.5 + wild);
                float a = atan2(p.y, p.x) - spin;
                float reach = kaleidoscopeMetalReach(spectrum, a, wedge);
                if (reach > 0.0) {
                    float e = 0.01;
                    float ahead = kaleidoscopeMetalReach(spectrum, a + e, wedge);
                    float behind = kaleidoscopeMetalReach(spectrum, a - e, wedge);
                    float slope = (ahead > 0.0 && behind > 0.0) ? (ahead - behind) / (2.0 * e * max(r, 0.05)) : 0.0;
                    float d = abs(r - reach) / sqrt(1.0 + slope * slope);
                    float period = wedge * 2.0;
                    float pair = floor(a / period);
                    float fold = 2.0 * pair + (a - pair * period >= wedge * 0.5 ? 1.0 : 0.0);
                    float tint = fold / folds + u.misc.w * 0.1;
                    col += paletteAt(u, tint) * (0.55 + 0.4 * energy) * smoothstep(0.016, 0.003, d);
                }
                col = fxTonemap(col, 1.3);
                col = fxFlash(col, u, 0.1);
                return float4(col, 1.0);
            }
            """#
    }
#endif
