#if canImport(Metal)
    /// Phosphor (Metal): a stereo-goniometer Lissajous burning into a dark CRT. Each trace is the waveform plotted
    /// against itself a quarter-period later and rotated 45 degrees; the newest is a hot white-cored beam with a wide
    /// bloom, and five older ones persist behind it, shrinking toward the center, fading and shifting along the
    /// palette. Behind them a graticule with axes, rings and the 45-degree diagonals lights up under the beam; in
    /// front, scanlines and a lens vignette. Bass swells the center glow and the inner rings, highs light the outer
    /// graticule and shed dust; a kick pushes the trace out and throws a ring; a snare throws a wide one; the beat sends
    /// a faint ring out every beat. The Metal port of the Canvas `phosphor`.
    enum PhosphorMetalShader {
        static let source = #"""
            // Dust flying out of the center and growing, in two zoom layers half a cycle apart.
            static float3 phosphorMetalDust(float2 p, float zoom, float seed, float density, float time, float3 tint) {
                FxZoomLayer layer = fxZoomLayer(p, zoom);
                float2 c;
                float h;
                if (!fxCell(layer.q, 0.16, seed, density, c, h)) return float3(0.0);
                c += 0.02 * float2(sin(time * 1.3 + h * 6.28), cos(time * 1.1 + h * 9.0));
                float screenDistance = length(c) * layer.scale;
                float reach = smoothstep(0.25, 0.6, screenDistance) * smoothstep(1.8, 1.2, screenDistance);
                float2 rel = layer.q - c;
                return tint * exp(-dot(rel, rel) * 9000.0 / (0.5 + h)) * layer.fade * reach;
            }

            // The trace point at index `j` (wrapping) of a history layer: the waveform against itself 11 points on.
            static float2 phosphorMetalPoint(constant float *history, int age, int j, float scale) {
                float a = history[age * 128 + j];
                float b = history[age * 128 + ((j + 11) & 127)];
                return float2((a - b) * 0.7071 * scale, -(a + b) * 0.7071 * scale);
            }

            // The newest trace's point at sample `i` of the live waveform: against itself 32 samples on.
            static float2 phosphorMetalLive(constant float *wave, int i, float scale) {
                float a = wave[i];
                float b = wave[(i + 32) & 511];
                return float2((a - b) * 0.7071 * scale, -(a + b) * 0.7071 * scale);
            }

            fragment float4 phosphorMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]], constant float *history [[buffer(5)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float travel = u.misc.z * intensity;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);
                float beatPhase = fract(beats);
                float beatPulse = pow(1.0 - beatPhase, 3.0);
                float px = u.resTime.y;

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.03 * intensity;
                float r = length(p);
                float3 deep = mix(u.c0.rgb, u.c1.rgb, 0.5);

                // Far: the glass, a glow at the center that follows the bass and the kick, and dust flying outward.
                float3 col = float3(0.002, 0.004, 0.008) + deep * exp(-r * r * 1.8) * (0.025 + 0.05 * energy + 0.12 * bass + 0.08 * kick);
                float3 dustTint = mix(float3(0.7, 0.85, 1.0), u.c2.rgb, 0.4) * (0.35 + 1.0 * highs + 0.5 * hat);
                col += phosphorMetalDust(p, fract(travel * 0.07), 2.0, 0.3, time, dustTint) * 0.7;
                col += phosphorMetalDust(p, fract(travel * 0.07 + 0.5), 2.5, 0.3, time, dustTint) * 0.7;

                float scale = 0.8 * (1.0 + 0.1 * kick * intensity);

                // The newest trace, from the live waveform's 256 segments, then the persistence of the five older ones.
                float core = 0.0;
                float halo = 0.0;
                float wBeam = 0.0062;
                float near = 0.0;
                if (r < 1.25) {
                    float2 prev = phosphorMetalLive(wave, 0, scale);
                    for (int j = 2; j < 512; j += 2) {
                        float2 cur = phosphorMetalLive(wave, j, scale);
                        float d = fxSegment(p, prev, cur);
                        core += exp(-d * d / (wBeam * wBeam));
                        halo += exp(-d / (wBeam * 4.5));
                        near = max(near, exp(-d * 9.0));
                        prev = cur;
                    }
                    float3 trail = float3(0.0);
                    for (int age = 1; age < 6; age++) {
                        float s = scale * (1.0 - 0.055 * float(age));
                        float fade = pow(0.68, float(age));
                        float2 a0 = phosphorMetalPoint(history, age, 0, s);
                        float acc = 0.0;
                        for (int j = 2; j < 128; j += 2) {
                            float2 a1 = phosphorMetalPoint(history, age, j, s);
                            float d = fxSegment(p, a0, a1);
                            acc += exp(-d * d / (wBeam * wBeam * 1.4)) + 0.25 * exp(-d / (wBeam * 3.0));
                            a0 = a1;
                        }
                        trail += paletteAt(u, float(age) * 0.09) * acc * fade * 0.45;
                    }
                    col += trail;
                }

                // The graticule: a 0.2 grid, axes, two rings and the 45-degree diagonals; the beam lights the glass
                // near it, the bass the inner part and the highs the outer part.
                {
                    float2 g = abs(fract(p / 0.2 + 0.5) - 0.5) * 0.2;
                    float lines = exp(-pow(g.x * px * 0.5, 2.0)) + exp(-pow(g.y * px * 0.5, 2.0));
                    float axes = exp(-pow(p.x * px * 0.5, 2.0)) + exp(-pow(p.y * px * 0.5, 2.0));
                    float diagonal = exp(-pow((abs(p.x) - abs(p.y)) * px * 0.35, 2.0)) * smoothstep(1.3, 0.2, r);
                    float rings = exp(-pow((r - 0.4) * px * 0.5, 2.0)) + exp(-pow((r - 0.8) * px * 0.5, 2.0));
                    float zone = 0.45 + 1.4 * bass * exp(-r * r * 3.0) + 1.0 * highs * smoothstep(0.3, 1.0, r);
                    float3 gridTint = mix(u.c0.rgb, u.c1.rgb, 0.5);
                    col += gridTint * (lines * 0.07 + axes * (0.1 + 0.12 * beatPulse) + diagonal * 0.05 + rings * 0.08) * zone * (1.0 + 4.0 * near) * (0.7 + 0.7 * kick);
                }

                // Rings: one leaves the center on every beat, a kick throws a bright one and a snare a wide one.
                {
                    float beatR = 0.1 + beatPhase * 1.4;
                    col += u.c0.rgb * exp(-pow((r - beatR) * px * 0.25, 2.0)) * 0.06 * pow(1.0 - beatPhase, 2.0);
                    float kickR = 0.15 + (1.0 - kick) * 0.9;
                    col += mix(u.c1.rgb, float3(1.0), 0.3) * exp(-pow((r - kickR) / 0.012, 2.0)) * kick * kick * 0.55;
                    float snareR = 0.3 + (1.0 - snare) * 1.2;
                    col += mix(u.c2.rgb, float3(1.0), 0.4) * exp(-pow((r - snareR) / 0.016, 2.0)) * snare * snare * 0.4;
                }

                // The beam: a hot white core and a wide bloom; the bass swells the bloom and a kick flares it.
                float3 hot = mix(u.c1.rgb, float3(1.0), 0.5);
                col += (hot * min(core, 2.5) * 0.7 + u.c1.rgb * halo * (0.02 + 0.014 * bass)) * (1.0 + 0.9 * kick);
                col += u.c1.rgb * exp(-r * 4.0) * 0.05 * (0.4 + 2.0 * bass) * near;

                // CRT: scanlines, and a lens vignette.
                col *= 0.88 + 0.12 * sin(in.uv.y * px * 3.14159);
                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.35);
                col = fxVignette(col, p, 0.16);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
