#if canImport(Metal)
    /// Particle field (Metal): the kick-driven particle field. A glow at the center swells on the kick and with the
    /// energy; every kick throws a ring and a burst of sparks from it, snares add streaks and hats add blocks, and in
    /// a build an arc around the core fills toward the drop. The particles are the state's own pool (buffer 8: a
    /// header float4, then two float4s per particle), so the picture is the same one the old Canvas drew, only on the
    /// GPU. The Metal port of the Canvas `ParticleFieldView`.
    enum ParticleFieldMetalShader {
        static let source = #"""
            fragment float4 particleFieldMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float4 *particles [[buffer(8)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float kick = u.env.x;
                float energy = u.wobble.z;
                // Unit space: 1 is half the shorter side, y down, centered on the (shaken) middle.
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0 - u.fx.zw;
                float r = length(p);

                // The core: a glow that swells on the kick and with the energy.
                float coreR = 0.16 + 0.22 * kick + 0.1 * energy;
                float g = r / (coreR * 2.4);
                float glow = exp(-g * g * 3.0);
                float3 col = paletteAt(u, 0.05) * 0.85 * glow + paletteAt(u, 0.4) * 0.25 * exp(-g * g * 1.2);

                // The build: an arc around the core fills as the phrase builds toward the drop.
                float build = particles[0].y;
                if (build > 0.01) {
                    float turn = fract((atan2(p.y, p.x) + 1.5707963) / 6.2831853);
                    float on = step(turn, min(build, 1.0));
                    float d = abs(r - 0.42);
                    col += paletteAt(u, 0.55) * (0.55 + 0.35 * build) * on * smoothstep(0.02, 0.004, d);
                }

                int count = int(particles[0].x);
                for (int i = 0; i < count; i++) {
                    float4 a = particles[1 + 2 * i];  // x, y, age, size
                    if (a.z >= 1.0) continue;
                    float4 b = particles[2 + 2 * i];  // vx, vy, tint, kind
                    float fade = 1.0 - a.z;
                    int kind = int(b.w);
                    if (kind == 0) {
                        float rad = 0.014 * a.w * (0.4 + fade);
                        float d = length(p - a.xy);
                        col += paletteAt(u, b.z) * fade * smoothstep(rad * 1.5, rad * 0.5, d);
                    } else if (kind == 1) {
                        float radius = 0.15 + 1.05 * a.z;
                        float width = max(0.006, 0.0175 * fade);
                        col += paletteAt(u, b.z + 0.1) * fade * 0.9 * smoothstep(width * 1.3, width * 0.3, abs(r - radius));
                    } else if (kind == 2) {
                        float2 tail = a.xy - b.xy * 0.06;
                        float d = fxSegment(p, tail, a.xy);
                        col += paletteAt(u, b.z) * fade * smoothstep(0.012, 0.002, d);
                    } else {
                        float2 q = p - a.xy;
                        float inside = step(0.0, q.x) * step(q.x, a.w) * step(0.0, q.y) * step(q.y, a.w * 0.12);
                        col += paletteAt(u, b.z) * fade * 0.6 * inside;
                    }
                }
                col = fxTonemap(col, 1.2);
                col = fxFlash(col, u, 0.12);
                return float4(col, 1.0);
            }
            """#
    }
#endif
