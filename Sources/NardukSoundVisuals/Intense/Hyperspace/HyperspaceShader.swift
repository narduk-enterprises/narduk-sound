#if canImport(Metal)
    /// Hyperspace + lasers: warp-speed star streaks with chromatic aberration, and laser beams through volumetric fog
    /// that sweep on the beat and strobe on the snare. One analytic pass, no bloom pass: the glow is a distance
    /// falloff. The strobe is `extra.x`, already rationed by `IntenseFlashLimiter`, so no more than three a second.
    enum HyperspaceShader {
        static let source = #"""
            // One layer of star streaks. Stars sit in angular cells; each star's radius runs 0 -> rim and accelerates
            // (pow), and its streak trails behind it, longer when the drop stretches the warp.
            static float streakLayer(float2 p, float travel, float speed, float count, float seed, float stretch, float px) {
                float r = length(p);
                float a = atan2(p.y, p.x) / 6.28318 + 0.5;
                float cell = a * count;
                float id = floor(cell);
                float ang = fract(cell) - 0.5;
                float h = hash11(id + seed);
                float h2 = hash11(id * 1.37 + seed + 9.1);
                float off = (h - 0.5) * 0.6;
                float s = fract(h2 + travel * speed * (0.6 + 0.8 * h));
                float rad = pow(s, 1.7) * 1.6;
                float len = (0.25 + 1.0 * stretch) * rad + 0.01;
                float dAng = (ang - off) * 6.28318 * max(r, 0.03);
                float w = px * 1.6 + 0.0012 * (1.0 + 2.0 * rad);
                float lateral = exp(-(dAng * dAng) / (w * w));
                float radial = smoothstep(rad - len, rad, r) * (1.0 - smoothstep(rad, rad + 0.012, r));
                float fade = smoothstep(0.0, 0.18, s);
                return lateral * radial * fade * (0.8 + 1.6 * s);
            }

            static float3 stars(float2 p, float scale, constant IntenseUniforms &u, float stretch, float px) {
                float travel = u.misc.z;
                float3 col = float3(0.0);
                for (int layer = 0; layer < 4; layer++) {
                    float fl = float(layer);
                    float3 tint = mix(paletteAt(u, fl * 0.27 + 0.05), float3(1.0), 0.55);
                    float v = streakLayer(p * scale, travel, 0.55 + 0.3 * fl, 70.0 + 38.0 * fl, fl * 31.7, stretch, px);
                    col += tint * v;
                }
                return col;
            }

            // The laser rig: beams from the top and bottom edges, each sweeping on its own beat multiple, lit by fog
            // that drifts. Calm narrows the sweep.
            static float3 lasers(float2 p, constant IntenseUniforms &u, float fog) {
                float beats = u.resTime.w;
                float kick = u.env.x;
                float drop = u.misc.y;
                float strobe = u.extra.x;
                float intensity = u.extra.z;
                int count = 5 + int(round(4.0 * drop));
                float3 col = float3(0.0);
                for (int i = 0; i < 9; i++) {
                    if (i >= count) break;
                    float fi = float(i);
                    bool top = (i % 2) == 0;
                    float2 src = float2(mix(-1.5, 1.5, (fi + 0.5) / 9.0), top ? 1.15 : -1.15);
                    float ang = sin(beats * (0.5 + 0.13 * fi) + fi * 1.7) * 0.95 * intensity;
                    float2 d = float2(sin(ang), cos(ang) * (top ? -1.0 : 1.0));
                    float2 rel = p - src;
                    float along = dot(rel, d);
                    float dist = abs(rel.x * d.y - rel.y * d.x);
                    float width = 0.010 + 0.02 * kick;
                    float core = exp(-(dist * dist) / (width * width));
                    float glow = exp(-dist * 5.0) * 0.28;
                    float atten = smoothstep(0.0, 0.25, along) * exp(-along * 0.32);
                    float scatter = glow * (0.45 + 1.1 * fog);
                    float beam = (core * 1.5 + scatter) * atten * (0.5 + 1.2 * strobe);
                    float3 tint = paletteAt(u, fi / 9.0 + beats / 32.0);
                    col += mix(tint, float3(1.0), core * 0.6) * beam;
                }
                return col * (0.55 + 0.7 * drop);
            }

            fragment float4 hyperspaceFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float time = u.resTime.z;
                float kick = u.env.x;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float intensity = u.extra.z;
                float px = 2.0 / u.resTime.y;

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.04 * intensity;
                p *= 1.0 - 0.05 * kick * intensity;

                // Chromatic aberration: the streaks are drawn three times at slightly different scales.
                float ca = (0.006 + 0.05 * u.fx.y + 0.02 * energy) * intensity;
                float stretch = (0.45 + 0.55 * drop) * (0.4 + 0.6 * intensity);
                float3 sr = stars(p, 1.0 + ca, u, stretch, px);
                float3 sg = stars(p, 1.0, u, stretch, px);
                float3 sb = stars(p, 1.0 - ca, u, stretch, px);
                float3 col = float3(sr.r, sg.g, sb.b) * (0.9 + 0.5 * energy);

                float fog = fbm(p * 1.6 + float2(time * 0.04, -time * 0.025));
                float3 bg = (u.c0.rgb * 0.05 + u.c1.rgb * 0.035 * fog) * (0.6 + 0.8 * length(p) * 0.3);
                col += bg + lasers(p, u, fog);

                // A soft core where the warp converges, breathing with the bass.
                float core = exp(-dot(p, p) * 9.0) * (0.12 + 0.35 * bandAt(spectrum, 0.05) + 0.25 * kick);
                col += mix(u.c1.rgb, float3(1.0), 0.5) * core;

                // The rationed flash: already limited on the CPU, tinted red-safe.
                col += u.flashColor.rgb * u.extra.x * 0.32;

                col = 1.0 - exp(-col * 1.35);
                col *= 1.0 - 0.28 * dot(p, p) * 0.35;
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
