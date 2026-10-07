#if canImport(Metal)
    /// Mirror (Metal): a symmetric spectrum of lit neon slabs standing on a glossy neon floor under a far mountain
    /// skyline. Bass sits at the center and the highs run out to both edges (the bass slabs widen in a drop); each slab has
    /// a cylinder-lit body, a hot top and a peak-hold cap, with embers rising off the tops. The floor is a perspective
    /// grid whose rows roll toward the viewer once per beat, lit from underneath by the slabs and showing their reflection.
    /// The horizon carries the live waveform as a hot beam. The kick brightens the grid, the glow and the beam; the
    /// snare throws a streak along the horizon; the highs dust the sky. The Metal port of the Canvas `mirror`.
    enum MirrorMetalShader {
        static let source = #"""
            // The weight of band `i`: the bass bands widen in a drop.
            static float mirrorMetalWeight(int i, float drop) {
                return 1.0 + drop * 1.6 * max(0.0, 1.0 - float(i) / 12.0);
            }

            // The slab at distance `f` (0 at the center, 1 at the edge) from the center line: its band, the position
            // across it (-1 ... 1) and its width. Returns the band, or -1 outside the bars.
            static int mirrorMetalBand(float f, float drop, thread float &across) {
                float total = 0.0;
                for (int i = 0; i < 64; i++) total += mirrorMetalWeight(i, drop);
                float t = f * total;
                float edge = 0.0;
                for (int i = 0; i < 64; i++) {
                    float w = mirrorMetalWeight(i, drop);
                    if (t < edge + w) {
                        across = ((t - edge) / w - 0.5) * 2.0;
                        return i;
                    }
                    edge += w;
                }
                across = 0.0;
                return -1;
            }

            // The lit slab body at height `y` above the horizon (0 ... 1 of the full height), for a band of level `v`.
            static float3 mirrorMetalSlab(
                constant IntenseUniforms &u, int band, float across, float y, float v, float maxHeight, float3 light, float kick) {
                float t = clamp(y / max(v * maxHeight, 1e-3), 0.0, 1.0);
                float z = sqrt(max(1.0 - across * across * 0.8, 0.0));
                float2 lit = fxLight(float3(across * 0.9, 0.0, z), light, 22.0);
                float3 tint = paletteAt(u, float(band) / 63.0 * 0.66);
                tint = tint * (1.0 + 0.45 * (tint / max(dot(tint, float3(0.333)), 0.05) - 1.0));
                float3 body = tint * (0.12 + 1.1 * pow(t, 1.1)) * (0.45 + 0.8 * lit.x);
                body += mix(tint, float3(1.0), 0.75) * pow(t, 5.0) * 0.8;
                body += float3(1.0) * lit.y * 0.35;
                return body * (1.0 + 0.5 * kick * (1.0 - t));
            }

            fragment float4 mirrorMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float travel = u.misc.z * intensity;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);
                float beatPulse = pow(1.0 - fract(beats), 3.0);
                float3 light = fxKeyLight();

                float2 uv = in.uv + u.fx.zw * 0.004 * intensity;
                float horizon = 0.63;
                float maxHeight = horizon * 0.84;
                float px = u.resTime.y;
                float2 p = (uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float f = abs(uv.x - 0.5) / 0.47;
                float3 deep = mix(u.c0.rgb, u.c1.rgb, 0.5);

                // Far: the sky, a glow on the horizon that breathes with the bass, stars, and a mountain skyline.
                float3 col = float3(0.003, 0.005, 0.014);
                float above = max(horizon - uv.y, 0.0);
                col += deep * exp(-above * 3.2) * (0.06 + 0.12 * energy + 0.2 * bass + 0.12 * kick) * (0.45 + 0.55 * exp(-pow((uv.x - 0.5) * 2.2, 2.0)));
                col += mix(float3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(float2(uv.x * aspect, uv.y), 24.0, 8.0, time) * (0.25 + 0.7 * highs) * smoothstep(0.0, 0.35, above);
                float ridge = horizon - 0.12 - 0.22 * fbm(float2(uv.x * 4.0 + 3.0, 1.7)) - 0.07 * fbm(float2(uv.x * 14.0, 4.0));
                float mountain = smoothstep(0.003, -0.003, ridge - uv.y) * step(uv.y, horizon);
                col = mix(col, float3(0.002, 0.003, 0.008), mountain);
                col += u.c0.rgb * exp(-pow((uv.y - ridge) * 90.0, 2.0)) * (0.15 + 0.4 * energy + 0.3 * kick) * step(ridge, uv.y) * step(uv.y, horizon);

                // The floor: a perspective grid rolling toward the viewer once per beat, lit from below by the slabs.
                if (uv.y > horizon) {
                    float v = (uv.y - horizon) / (1.0 - horizon);
                    float roll = fract(beats);
                    // Rows: the depth coordinate is v = u^2, so u = sqrt(v); rows sit at (k + roll) / 9.
                    float rowCoord = sqrt(v) * 9.0 - roll;
                    float rowD = abs(fract(rowCoord + 0.5) - 0.5) / (9.0 * 0.5 / max(sqrt(v), 0.05)) * (1.0 - horizon);
                    float rowLine = exp(-pow(rowD * px * 0.55, 2.0));
                    float columns = (uv.x - 0.5) / max(0.018 + 0.142 * v, 1e-3);
                    float columnD = abs(fract(columns + 0.5) - 0.5) * (0.018 + 0.142 * v);
                    float columnLine = exp(-pow(columnD * px * aspect * 0.55, 2.0));
                    float grid = max(rowLine, columnLine * 0.8);
                    float pool = pow(bandAt(spectrum, clamp(f, 0.0, 1.0) * 0.9), 0.7);
                    float fade = exp(-v * 1.3);
                    col += mix(u.c0.rgb, u.c1.rgb, 0.4) * grid * (0.22 + 0.4 * kick + 0.6 * pool * fade) * (0.35 + 0.65 * fade);
                    col += deep * pool * exp(-v * 5.0) * 0.12 * (1.0 + kick);
                }

                // The slabs, and their reflection in the floor.
                {
                    bool isFloor = uv.y > horizon;
                    float yAbove = isFloor ? (uv.y - horizon) * 1.12 : horizon - uv.y;
                    float wobble = isFloor ? 0.002 * sin((uv.y - horizon) * 90.0 - time * 4.0) * (0.4 + highs) : 0.0;
                    float across;
                    int band = f < 1.0 ? mirrorMetalBand(clamp(f + wobble, 0.0, 0.999), drop, across) : -1;
                    if (band >= 0) {
                        float v = min(pow(spectrum[band], 0.85), 1.0);
                        float gapAcross = smoothstep(1.0, 0.72, abs(across));
                        float topY = max(v * maxHeight, 0.004);
                        float inside = smoothstep(topY, topY - 0.004, yAbove) * gapAcross * smoothstep(0.0, 0.004, yAbove + 0.002);
                        float3 slab = mirrorMetalSlab(u, band, across, yAbove, v, maxHeight, light, kick);
                        float strength = isFloor ? 0.22 * exp(-(yAbove) * 2.4) : 1.0;
                        col += slab * inside * strength;
                        // Bloom above the top and sideways into the gap.
                        float3 tint = paletteAt(u, float(band) / 63.0 * 0.66);
                        float bloom = exp(-max(yAbove - topY, 0.0) * 12.0) * smoothstep(0.0, 0.02, topY) * (1.0 - inside) * smoothstep(1.5, 0.5, abs(across));
                        col += tint * bloom * v * (0.28 + 0.2 * bass) * (isFloor ? 0.25 : 1.0) * (1.0 + 0.8 * kick);
                        if (!isFloor) {
                            // The peak-hold cap, and an ember rising off the top.
                            float peakY = pow(max(aux[band], 0.0), 0.85) * maxHeight + 0.018;
                            float cap = exp(-pow((yAbove - peakY) * 150.0, 2.0)) * gapAcross;
                            col += mix(tint, float3(1.0), 0.75) * cap * 0.9 * step(0.02, aux[band]);
                            float h = hash11(float(band) * 7.3);
                            float rise = fract(time * (0.22 + 0.2 * h) + h * 5.0);
                            float2 ember = float2(across * 0.0, topY + 0.02 + rise * 0.26);
                            float2 dp = float2(across * 0.5 * 0.012 * aspect * 2.0, (yAbove - ember.y) * 1.0);
                            col += mix(tint, float3(1.0), 0.6) * exp(-dot(dp, dp) * 30000.0) * (1.0 - rise) * (0.3 + hat * 1.2 + 0.6 * v) * step(0.12, v);
                        }
                    }
                }

                // The horizon: a hot beam that carries the live waveform, and a streak a snare throws along it.
                {
                    float i = clamp(uv.x, 0.0, 1.0) * 510.0;
                    float k0 = floor(i);
                    float w0 = mix(wave[int(k0)], wave[int(k0) + 1], i - k0);
                    float wl = wave[int(max(k0 - 3.0, 0.0))];
                    float wr = wave[int(min(k0 + 4.0, 511.0))];
                    float yb = horizon + w0 * 0.035;
                    float slope = ((wr - wl) * 0.035) / (7.0 / 511.0 * aspect);
                    float d = abs(uv.y - yb) / sqrt(1.0 + slope * slope);
                    float2 beam = fxBeam(d, 0.0034 + 0.001 * kick);
                    float edgeFade = smoothstep(0.0, 0.05, uv.x) * smoothstep(1.0, 0.95, uv.x);
                    col += (mix(u.c1.rgb, float3(1.0), 0.6) * beam.x * 1.5 + u.c1.rgb * beam.y * 1.2) * (1.0 + 0.7 * kick + 0.3 * beatPulse) * edgeFade;
                    col += mix(u.c2.rgb, float3(1.0), 0.4) * exp(-pow((uv.y - horizon) * 14.0, 2.0)) * snare * 0.25 * smoothstep(0.0, 0.5, 1.0 - abs(uv.x - 0.5) * 1.6);
                }

                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
