#if canImport(Metal)
    /// The wobble tunnel's Metal Shading Language source, compiled at runtime by `WobbleTunnelRenderer`.
    ///
    /// It is a string, not a `.metal` file: SwiftPM would need a `resources:` entry in the root manifest (and the
    /// optional Metal Toolchain at build time), while a string needs neither and one compile per process is cheap.
    /// Ported from Wirewatcher's `WobbleTunnel.msl`.
    enum WobbleTunnelShader {
        static let source = #"""
            #include <metal_stdlib>
            using namespace metal;

            // Network Dubstep hero visualizer: a neon tunnel whose walls breathe with the wobble
            // filter, rings pass one per beat, kicks punch the camera forward, snares split the
            // color channels, and the drop flashes white. One full-screen pass; the glow is analytic
            // (distance falloff), so there is no bloom pass to pay for.
            //
            // Layout must match WobbleTunnelUniforms in WobbleTunnelRenderer.swift (8 x float4).
            // This source ships as a Swift string and is compiled at runtime by WobbleTunnelRenderer, so building the
            // package needs neither a `resources:` entry nor the optional Metal Toolchain.
            struct TunnelUniforms {
                float4 resTime;   // width, height, time (s), beats
                float4 env;       // kick, snare, hat, impact
                float4 wobble;    // cutoff, phase, energy, glitch
                float4 fx;        // flash, chroma, shakeX, shakeY
                float4 misc;      // wild (live traffic blended with energy), dropAmount, travel, barPhase
                float4 c0;
                float4 c1;
                float4 c2;
            };

            struct TunnelVertexOut {
                float4 position [[position]];
                float2 uv;
            };

            vertex TunnelVertexOut tunnelVertex(uint vid [[vertex_id]]) {
                // One oversized triangle covering the viewport.
                float2 p = float2(float((vid << 1) & 2), float(vid & 2));
                TunnelVertexOut out;
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

            static float3 paletteAt(constant TunnelUniforms &u, float t) {
                float f = fract(t) * 3.0;
                float s = fract(f);
                s = s * s * (3.0 - 2.0 * s);
                if (f < 1.0) return mix(u.c0.rgb, u.c1.rgb, s);
                if (f < 2.0) return mix(u.c1.rgb, u.c2.rgb, s);
                return mix(u.c2.rgb, u.c0.rgb, s);
            }

            // Distance to the nearest integer, 0 ... 0.5.
            static float gridDistance(float x) {
                return abs(fract(x + 0.5) - 0.5);
            }

            static float3 tunnel(float2 p, float px, constant TunnelUniforms &u, constant float *spectrum, constant float *wave) {
                float time = u.resTime.z;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float cutoff = u.wobble.x;
                float wobblePhase = u.wobble.y;
                float energy = u.wobble.z;
                float dropAmount = u.misc.y;
                float travel = u.misc.z;

                float r = length(p);
                float a = atan2(p.y, p.x);

                // The wobble: the tunnel cross-section bulges into lobes that rotate with the LFO
                // phase and deepen with the filter cutoff.
                float lobes = 4.0 + 2.0 * dropAmount;
                float warp = 1.0 + (0.05 + 0.24 * cutoff) * sin(a * lobes + wobblePhase * 6.28318 + time * 0.2)
                    * smoothstep(0.02, 0.5, r);
                float rr = max(r * warp, 1e-3);

                float z = 1.1 / rr;             // depth: ~1 at the rim, large toward the center
                float zz = z + travel;
                // Rotation is locked to the bar: one revolution per four bars.
                float spin = a / 6.28318 + 0.5 + beats / 16.0;

                float ringD = gridDistance(zz);
                float spokeCount = 24.0;
                float spokeD = gridDistance(spin * spokeCount);
                // Analytic pixel footprints (px = one pixel in p units) for anti-aliased lines.
                float ringW = 1.1 / (rr * rr) * px + 1e-4;
                float spokeW = spokeCount * px / (6.28318 * max(r, 1e-3)) + 1e-4;

                // Mirror the spectrum around the tunnel: bass at the floor and ceiling, highs at the sides.
                float fa = abs(fract(spin) * 2.0 - 1.0);
                float bandV = bandAt(spectrum, fa);

                float ringLine = 1.0 - smoothstep(0.0, ringW * 1.5, ringD);
                float ringGlow = exp(-ringD / (ringW * 6.0 + 0.02)) * 0.55;
                float minorD = gridDistance(zz * 4.0) / 4.0;
                float minorLine = (1.0 - smoothstep(0.0, ringW * 1.2, minorD)) * 0.35;
                float spokeLine = 1.0 - smoothstep(0.0, spokeW * 1.5, spokeD);
                float spokeGlow = exp(-spokeD / (spokeW * 5.0 + 0.02)) * 0.3;

                // Spectrum tiles: wall panels light when their band is loud; rows travel with the rings.
                float2 tile = float2(floor(zz * 2.0), floor(spin * spokeCount));
                float tileFill = step(hash21(tile) * 1.15, bandV * (0.45 + 0.6 * energy)) * 0.22 * smoothstep(0.0, 0.08, 0.5 - max(gridDistance(zz * 2.0 + 0.5), spokeD));

                float3 base = paletteAt(u, zz * 0.11 + fa * 0.35 + time * 0.015);
                float intensity = (ringLine + ringGlow) * (0.45 + 1.6 * bandV) + minorLine * (0.2 + 0.8 * bandV) + (spokeLine + spokeGlow) * (0.2 + 0.6 * bandV) + tileFill;
                float3 col = base * intensity;

                // Fog into the vanishing point, then a pulsing core light there.
                float fog = exp(-(z - 1.0) * (0.2 - 0.06 * energy));
                col *= fog;
                float core = exp(-r * (10.0 - 5.0 * kick)) * (0.5 + 1.8 * kick + 0.6 * energy);
                col += mix(u.c1.rgb, float3(1.0), 0.45) * core;

                // Oscilloscope ring around the core: the live waveform wrapped onto a circle.
                float ringRadius = 0.16 + 0.05 * kick;
                // Sample the waveform mirrored (0→1→0) so the ring closes without a seam.
                float sample = waveAt(wave, abs(fract(a / 6.28318 + 0.5 + beats / 16.0) * 2.0 - 1.0) * 0.998);
                float scopeD = abs(r - ringRadius - sample * 0.06 * (0.6 + energy));
                col += mix(u.c0.rgb, float3(1.0), 0.3) * (exp(-scopeD * 160.0) * 1.1 + exp(-scopeD * 30.0) * 0.25);

                return col;
            }

            fragment float4 tunnelFragment(TunnelVertexOut in [[stage_in]],
                                           constant TunnelUniforms &u [[buffer(0)]],
                                           constant float *spectrum [[buffer(1)]],
                                           constant float *wave [[buffer(2)]]) {
                float2 res = u.resTime.xy;
                float time = u.resTime.z;
                float kick = u.env.x;
                float glitch = u.wobble.w;
                float flash = u.fx.x;
                float chroma = u.fx.y;

                float2 uv = in.uv;
                // Glitch: horizontal block displacement for a few frames after a glitch hit.
                if (glitch > 0.02) {
                    float row = floor(uv.y * 28.0);
                    float h = hash21(float2(row, floor(time * 24.0)));
                    if (h > 0.72) uv.x += (h - 0.72) * glitch * 0.5;
                }

                float px = 2.0 / min(res.x, res.y);
                float2 p = (uv * res - 0.5 * res) * px;
                p += u.fx.zw * 2.0;                 // camera shake
                p *= 1.0 - 0.13 * kick;              // kick zoom punch

                float3 col;
                if (chroma > 0.01) {
                    float2 dir = normalize(p + 1e-4) * chroma * 0.035;
                    col.r = tunnel(p * (1.0 + chroma * 0.03) + dir, px, u, spectrum, wave).r;
                    col.g = tunnel(p, px, u, spectrum, wave).g;
                    col.b = tunnel(p * (1.0 - chroma * 0.03) - dir, px, u, spectrum, wave).b;
                } else {
                    col = tunnel(p, px, u, spectrum, wave);
                }

                // Soft tonemap keeps the glow from clipping, then vignette, grain and the drop flash.
                // A wild network pushes the exposure: more bloom when traffic is busy.
                col = 1.0 - exp(-col * (1.05 + 0.55 * u.misc.x));
                float vignette = smoothstep(1.9, 0.35, length(p * float2(0.85, 1.0)));
                col *= mix(0.35, 1.0, vignette);
                col += (hash21(uv * res + fract(time) * 100.0) - 0.5) * 0.025;
                col = mix(col, float3(1.0), clamp(flash, 0.0, 1.0));
                return float4(max(col, 0.0), 1.0);
            }
            """#
    }
#endif
