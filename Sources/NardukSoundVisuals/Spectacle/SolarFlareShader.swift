#if canImport(Metal)
    /// Solar flare: a molten disc and a silky corona on black. Appended to `ShaderPackSource` so it shares
    /// `PackUniforms` and the pack's helpers (`hash21`, `bandAt`).
    ///
    /// Bass swells the disc and drives the tendrils out. Mids speed the curl and the surface churn. Highs sharpen
    /// the fibers and spark the embers. `env.x` (unless `fx.x` is calm) is a flare that travels out along the
    /// tendrils and brightens the limb. `misc.y` (`dropAmount`) whitens the core and lengthens the corona.
    enum SolarFlareShader {
        static let source = #"""

            static float flareNoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                float a = hash21(i);
                float b = hash21(i + float2(1.0, 0.0));
                float c = hash21(i + float2(0.0, 1.0));
                float d = hash21(i + float2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }

            static float flareFbm(float2 p) {
                float v = 0.0;
                float a = 0.5;
                v += a * flareNoise(p);
                p = p * 2.03 + float2(1.7, 9.2);
                a *= 0.5;
                v += a * flareNoise(p);
                p = p * 2.01 + float2(8.3, 2.8);
                a *= 0.5;
                v += a * flareNoise(p);
                return v / 0.875;
            }

            static float flareFbm2(float2 p) {
                float n = flareNoise(p);
                return (n + 0.5 * flareNoise(p * 2.03 + float2(1.7, 9.2))) / 1.5;
            }

            // Cell-center distance and the F2-F1 edge (thin where two cells meet).
            static float2 flareCells(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                float d1 = 8.0;
                float d2 = 8.0;
                for (int y = -1; y <= 1; y++) {
                    for (int x = -1; x <= 1; x++) {
                        float2 g = float2(float(x), float(y));
                        float2 o = float2(hash21(i + g), hash21(i + g + float2(19.19, 7.73)));
                        float2 diff = g + o - f;
                        float dd = dot(diff, diff);
                        if (dd < d1) {
                            d2 = d1;
                            d1 = dd;
                        } else if (dd < d2) {
                            d2 = dd;
                        }
                    }
                }
                return float2(sqrt(d1), sqrt(d2) - sqrt(d1));
            }

            fragment float4 solarFlareFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
                float r = length(p);
                float2 dir = p / max(r, 0.0008);
                float ang = atan2(dir.y, dir.x);

                float calm = u.fx.x;
                float motion = mix(1.0, 0.4, calm);
                float time = u.resTime.z * motion;
                float travel = u.misc.z * motion;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.4);
                float highs = bandAt(spectrum, 0.8);
                float kick = u.env.x * (1.0 - calm);
                float drop = u.misc.y;

                float3 deep = u.c0.rgb;
                float3 gold = u.c1.rgb;
                float3 hot = mix(u.c2.rgb, float3(1.0), 0.58 + 0.42 * drop);

                // 40% of the frame height, swelling slightly with the bass.
                float discR = 0.20 * (1.0 + 0.09 * bass + 0.025 * drop);
                // Tips reach the top and bottom of the frame; bass and the drop push them past it.
                float reach = 0.70 + 0.16 * bass + 0.12 * drop;
                float flow = travel * 0.10 + time * (0.16 + 0.95 * mids);
                float span = max(reach - discR, 0.08);
                float along = saturate((r - discR * 0.86) / span);

                // Domain-warped fbm on a circle (no seam). It is the current the tendrils swim in.
                float2 q = dir * 1.15 + float2(r * 1.1 - flow * 0.18, flow * 0.04);
                float n1 = flareFbm2(q);
                float n2 = flareFbm2(q + float2(5.2, 1.7));
                float curl = (n1 - 0.5) * (1.1 + 0.7 * mids) + (n2 - 0.5) * 0.4;

                // Two dozen wavy tendrils. Frequency and phase come from the tendril id, and the curl field
                // bends them, so they don't share one sine.
                float count = 24.0;
                float spacing = 6.2831853 / count;
                float id = floor((ang + 3.14159265) / spacing);
                float seed = hash21(float2(id, 2.3));
                float seed2 = hash21(float2(id, 8.1));
                float pace = flow * (0.7 + 1.6 * mids);
                float freq = mix(8.0, 18.0, seed);
                float amp = 0.040 + 0.055 * seed2;
                float local = sin(r * freq - pace * (0.5 + seed) + seed * 6.28318) * amp;
                local += sin(r * freq * 0.46 - pace * 0.32 + n2 * 6.0) * amp * 0.9;
                float a = ang + local + curl * 0.15;

                float cell = fract(a / spacing);
                float spine = abs(cell - 0.5);
                // Black gap between neighbouring tendrils. The strands themselves taper; this only separates bundles.
                float gap = smoothstep(0.49, 0.40, spine);

                // Warp along the tendril so brightness breaks like flame, not a solid bar.
                float2 polar = float2(a * 2.2 + curl, r * 2.2 - flow * 0.32);
                float n = flareFbm(polar + float2(n1, n2) * (1.15 + 0.4 * mids));
                float ridge = pow(1.0 - abs(n * 2.0 - 1.0), 1.2);
                float flameBreak = mix(0.45, 1.0, ridge);
                float tip = 0.86 + 0.14 * seed;
                float fade = 1.0 - smoothstep(tip * 0.78, tip, along);
                float spread = smoothstep(0.0, 0.22, along);

                // Three silky strands per tendril, separated by black. They twist around each other.
                // Highs add two more strands and cut every strand thinner.
                float strandSum = 0.0;
                float sigma = mix(0.0032, 0.00135, spread);
                sigma *= mix(1.0, 0.62, saturate(highs));
                for (int k = 0; k < 5; k++) {
                    float fk = float(k);
                    float extra = step(2.5, fk);
                    float show = mix(1.0, highs, extra);
                    float lane = mix(0.30 + 0.20 * min(fk, 2.0), mix(0.12, 0.88, step(3.5, fk)), extra);
                    float twist = sin(r * (12.0 + fk * 2.4) - pace + seed * 6.28318 + fk * 1.3);
                    twist *= 0.045 + 0.03 * spread;
                    float d = abs(cell - lane - twist);
                    strandSum += exp(-d * d / sigma) * show;
                }
                strandSum *= gap * flameBreak * fade;
                float mask = strandSum * 0.62;

                float3 flame = mix(gold, deep, smoothstep(0.0, 0.88, along));
                flame = mix(mix(gold, hot, 0.22), flame, smoothstep(0.0, 0.14, along));

                float pulseT = saturate(1.0 - kick);
                float pulseR = mix(discR * 1.06, min(reach, 0.62), pulseT);
                float pulse = exp(-abs(r - pulseR) * 18.0) * smoothstep(0.05, 0.25, kick);

                float3 col = float3(0.0);
                float gain = 1.15 + 1.35 * bass + 0.45 * drop;
                col += flame * mask * gain;
                col += mix(gold, hot, 0.4) * pulse * strandSum * 0.85;

                // Sparse embers in the black. Highs light more of them and make them twinkle.
                for (int i = 0; i < 16; i++) {
                    float fi = float(i);
                    float h = hash21(float2(fi + 0.5, 2.7));
                    float show = step(h, 0.28 + 0.72 * highs);
                    float angS = hash21(float2(fi, 8.2)) * 6.28318;
                    float rad = mix(discR + 0.05, 0.62, hash21(float2(fi, 4.4)));
                    angS += time * (0.045 + 0.10 * h) * (0.5 + mids);
                    rad += sin(time * (0.25 + h * 0.4) + fi) * 0.025;
                    float2 pos = float2(cos(angS), sin(angS)) * rad;
                    float outside = smoothstep(discR * 1.02, discR * 1.28, rad);
                    float d = length(p - pos);
                    float sz = 0.0032 + 0.0022 * highs;
                    float spark = exp(-d * d / (sz * sz)) * show * outside;
                    float twinkle = 0.5 + 0.5 * sin(time * (2.2 + highs * 9.0) + fi * 1.7);
                    float tw = mix(0.8, 0.25 + 0.75 * saturate(twinkle), saturate(highs * 1.15));
                    float3 ember = mix(deep, gold, 0.45 + 0.4 * h);
                    col += ember * spark * tw * 1.5;
                    col += hot * spark * spark * 0.8;
                }

                if (r < discR + 0.03) {
                    float nd = saturate(r / max(discR, 0.001));
                    float z = sqrt(saturate(1.0 - nd * nd));
                    float3 nrm = normalize(float3(dir * nd, z));
                    float3 light = normalize(float3(-0.34, 0.46, 0.82));
                    float diff = 0.50 + 0.50 * max(dot(nrm, light), 0.0);
                    float spec = pow(max(dot(reflect(-light, nrm), float3(0.0, 0.0, 1.0)), 0.0), 26.0);

                    float churn = time * (0.22 + 1.15 * mids);
                    float2 sp = dir * nd * 3.6;
                    sp += float2(sin(sp.y * 1.7 + churn), cos(sp.x * 1.5 - churn * 0.85)) * 0.42;
                    float2 cells = flareCells(sp);
                    float boil = flareNoise(sp * 0.65 + float2(churn * 0.15, 1.3));
                    float bright = 1.0 - smoothstep(0.02, 0.38, cells.x);
                    float crack = smoothstep(0.11, 0.012, cells.y);

                    float3 albedo = mix(deep * (0.42 + 0.2 * boil), mix(deep, gold, 0.82), bright);
                    albedo = mix(albedo, mix(gold, hot, 0.72), crack);
                    float core = exp(-nd * nd * (12.5 - 4.5 * drop));
                    float streaks = pow(
                        saturate(0.5 + 0.5 * cos(ang * (16.0 + 10.0 * highs) + boil * 7.0)), 28.0);
                    streaks *= smoothstep(0.82, 0.04, nd) * (0.22 + 0.5 * highs);
                    albedo = mix(albedo, hot, saturate(core * (1.05 + 0.85 * drop)));
                    albedo += hot * streaks * (0.22 + 0.45 * core);
                    albedo *= diff * (0.62 + 0.38 * z);
                    albedo += hot * spec * (0.18 + 0.35 * core);

                    float cover = 1.0 - smoothstep(discR - 0.008, discR + 0.003, r);
                    col = mix(col, albedo, cover);
                }

                float limb = exp(-abs(r - discR) * (150.0 - 45.0 * kick));
                col += hot * limb * (0.85 + 1.25 * kick);
                col += gold * limb * 0.35;

                col = 1.0 - exp(-col * 1.22);
                return float4(saturate(col), 1.0);
            }
            """#
    }
#endif
