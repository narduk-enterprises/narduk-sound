#if canImport(Metal)
    /// The shader pack's Metal Shading Language source, compiled at runtime by `ShaderPackRenderer` (a string, for
    /// the same reason as `WobbleTunnelShader`: no `resources:` entry and no Metal Toolchain at build time).
    ///
    /// Every fragment reads the same uniforms as the wobble tunnel (`WobbleTunnelUniforms`, 8 x float4), so one
    /// `fill` serves the whole pack. Nothing here strobes: motion is continuous, the only beat-locked change is a
    /// bounded glow, and the state's flash is never used; `fx.x` carries the calm flag instead.
    enum ShaderPackSource {
        static let source = #"""
            #include <metal_stdlib>
            using namespace metal;

            struct PackUniforms {
                float4 resTime;   // width, height, time (s), beats
                float4 env;       // kick, snare, hat, impact
                float4 wobble;    // cutoff, phase, energy, glitch
                float4 fx;        // calm flag (the pack's own use of the flash slot), chroma, shakeX, shakeY
                float4 misc;      // wild, dropAmount, travel, barPhase
                float4 c0;
                float4 c1;
                float4 c2;
            };

            struct PackVertexOut {
                float4 position [[position]];
                float2 uv;
            };

            vertex PackVertexOut packVertex(uint vid [[vertex_id]]) {
                float2 p = float2(float((vid << 1) & 2), float(vid & 2));
                PackVertexOut out;
                out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
                out.uv = float2(p.x, 1.0 - p.y);
                return out;
            }

            static float hash21(float2 p) {
                p = fract(p * float2(123.34, 456.21));
                p += dot(p, p + 45.32);
                return fract(p.x * p.y);
            }

            static float bandAt(constant float *spectrum, float x) {
                float f = clamp(x, 0.0, 1.0) * 63.0;
                int i = int(f);
                int j = min(i + 1, 63);
                return mix(spectrum[i], spectrum[j], fract(f));
            }

            static float waveAt(constant float *wave, float x) {
                float f = fract(x) * 511.0;
                int i = int(f);
                int j = (i + 1) % 512;
                return mix(wave[i], wave[j], fract(f));
            }

            static float3 paletteAt(constant PackUniforms &u, float t) {
                float f = fract(t) * 3.0;
                float s = fract(f);
                s = s * s * (3.0 - 2.0 * s);
                if (f < 1.0) return mix(u.c0.rgb, u.c1.rgb, s);
                if (f < 2.0) return mix(u.c1.rgb, u.c2.rgb, s);
                return mix(u.c2.rgb, u.c0.rgb, s);
            }

            // MARK: Plasma

            fragment float4 plasmaFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float t = u.resTime.z;
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 3.2;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.3);
                float highs = bandAt(spectrum, 0.7);
                float energy = u.wobble.z;
                float v = sin(p.x * 1.6 + t * 0.6) + sin(p.y * 1.9 - t * 0.5 + bass * 3.0)
                    + sin((p.x + p.y) * 1.2 + t * 0.4) + sin(length(p) * (2.0 + mids * 3.0) - t * 0.8 - u.env.x * 2.0);
                v = v * 0.25 + 0.5;
                float3 color = paletteAt(u, v + u.misc.z * 0.02);
                float light = 0.16 + 0.34 * energy + 0.22 * bass;
                color *= light;
                color += paletteAt(u, v + 0.5) * highs * 0.25;
                return float4(clamp(color, 0.0, 1.0), 1.0);
            }

            // MARK: Warp grid

            fragment float4 warpGridFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float t = u.resTime.z;
                float2 p = (in.uv * 2.0 - 1.0) * float2(aspect, 1.0);
                float bass = bandAt(spectrum, 0.05);
                float horizon = -0.1;
                float3 color = float3(0.0);
                float below = p.y - horizon;
                // Sky: a soft sun on the horizon that swells with the bass.
                float sun = exp(-length(p - float2(0.0, horizon - 0.25)) * (3.0 - bass * 1.2));
                color += paletteAt(u, 0.0) * sun * (0.5 + 0.5 * bass);
                if (below > 0.01) {
                    float z = 0.6 / below;
                    float x = p.x * z;
                    x += sin(z * 1.4 + t * 0.6) * (0.15 + 0.5 * bass);
                    float line = 0.04 + 0.02 * z;
                    float gx = smoothstep(line, 0.0, abs(fract(x * 0.5 + 0.5) - 0.5) * 2.0 / max(z, 1.0));
                    float gz = smoothstep(line, 0.0, abs(fract(z * 0.5 - u.misc.z + 0.5) - 0.5) * 2.0 / max(z, 1.0));
                    float fade = exp(-z * 0.12);
                    float3 grid = paletteAt(u, 0.15 + z * 0.02 + u.misc.z * 0.01);
                    color += grid * clamp(gx + gz, 0.0, 1.0) * fade * (0.6 + 0.6 * u.wobble.z + u.env.x * 0.4);
                }
                return float4(clamp(color, 0.0, 1.0), 1.0);
            }

            // MARK: Starfield

            fragment float4 starfieldFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
                float r = length(p);
                float a = atan2(p.y, p.x);
                float3 color = float3(0.0);
                float speed = 0.05 + 0.1 * u.misc.x;
                for (int layer = 0; layer < 4; layer++) {
                    float fl = float(layer);
                    float cells = 36.0 + fl * 17.0;
                    float angle = a / 6.28318 * cells + fl * 7.3;
                    float id = floor(angle);
                    float h = hash21(float2(id, fl + 1.0));
                    float z = fract(h + u.misc.z * (speed + fl * 0.03));
                    float radius = z * z * 1.1;
                    float cellCenter = (id + 0.5 + (h - 0.5) * 0.6);
                    float da = abs(angle - cellCenter) / cells * 6.28318 * max(r, 0.02);
                    float streak = 0.004 + z * 0.05 * (0.5 + u.misc.x);
                    float along = smoothstep(streak, 0.0, abs(r - radius));
                    float across = smoothstep(0.006 + z * 0.004, 0.0, da);
                    float twinkle = 0.7 + 0.3 * hash21(float2(id, floor(u.resTime.z * 4.0) + fl));
                    color += paletteAt(u, h + fl * 0.2) * along * across * z * twinkle * 2.2;
                }
                color += paletteAt(u, 0.6) * exp(-r * 6.0) * (0.15 + 0.4 * u.env.x);
                return float4(clamp(color, 0.0, 1.0), 1.0);
            }

            // MARK: Feedback
            //
            // Milkdrop-style: each frame samples the previous frame, zoomed and rotated a little and faded, then
            // draws a fresh waveform ring over it. The trails are the effect; the result is bounded (decay < 1).

            fragment float4 feedbackFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                texture2d<float> previous [[texture(0)]]
            ) {
                constexpr sampler s(address::clamp_to_edge, filter::linear);
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = u.fx.x;  // the pack reuses fx.x as the calm flag (the flash is never used here)
                float zoom = 1.0 - (0.010 + 0.022 * u.env.x + 0.008 * u.wobble.z);
                float turn = (0.004 + 0.010 * u.wobble.z) * (1.0 - 0.8 * calm) * sin(u.resTime.z * 0.3 + 1.0);
                float2 c = in.uv - 0.5;
                float cs = cos(turn), sn = sin(turn);
                c = float2(c.x * cs - c.y * sn, c.x * sn + c.y * cs) * zoom;
                float3 old = previous.sample(s, c + 0.5).rgb * (0.90 + 0.05 * u.wobble.z);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
                float r = length(p);
                float a = atan2(p.y, p.x);
                float turns = a / 6.28318 + 0.5;
                float w = waveAt(wave, turns);
                float band = bandAt(spectrum, abs(turns - 0.5) * 2.0);
                float ringRadius = 0.16 + w * 0.07 + u.env.x * 0.035 + band * 0.05;
                float glow = smoothstep(0.010 + band * 0.012, 0.0, abs(r - ringRadius));
                float3 fresh = paletteAt(u, turns + u.misc.z * 0.03) * glow * (0.55 + 0.9 * band);
                return float4(min(old + fresh, float3(1.0)), 1.0);
            }

            fragment float4 presentFragment(
                PackVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]]
            ) {
                constexpr sampler s(address::clamp_to_edge, filter::linear);
                return float4(source.sample(s, in.uv).rgb, 1.0);
            }
            """#
    }
#endif
