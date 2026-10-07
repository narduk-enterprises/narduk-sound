#if canImport(Metal)
    /// A flame-wreathed sun: wavy fire tendrils, a veined disc and drifting embers. Promoted from the SoundGallery drop-in plugin `flamesun.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum FlameSunShader {
        static let source = #"""
            // title: Flame sun
            // fragment: flameSunFragment

            // A blazing star wreathed in wavy flame tendrils, made of thousands of fine glowing strands, with a molten veined
            // surface and a white-hot core that bursts outward. The spectrum sets each tendril's reach (an equaliser running
            // around the sun), bass swells the disc, a kick flares every tendril and the core, a snare throws a shock ring,
            // hats sparkle the embers, the drop blows the corona wide.

            static float3 fsFire(float v) {
                // black -> deep red -> orange -> gold -> white
                v = max(v, 0.0);
                float3 c = float3(1.0, 0.32, 0.04) * smoothstep(0.0, 0.35, v);
                c += float3(0.0, 0.38, 0.06) * smoothstep(0.25, 0.75, v);
                c += float3(0.0, 0.22, 0.5) * smoothstep(0.7, 1.4, v);
                c *= 0.25 + 0.75 * smoothstep(0.0, 0.12, v);
                return c * (0.6 + v);
            }

            static float fsTendrils(float2 dir, float a, float r, float R, float t, float reach, float kick) {
                float d = max(r - R, 0.0);
                // The whole tendril sways: its angle wobbles more the farther out it reaches.
                float dc = min(d, 0.5);
                float sway = (fxNoise3(float3(dir * 1.3, d * 2.2 - t * 0.55)) - 0.5) * 0.9 * dc
                    + 0.14 * dc * sin(d * 10.0 - t * 2.6 + 3.0 * sin(a * 3.0));
                float aw = a + sway;
                const float N = 22.0;
                float lobe = 0.5 + 0.5 * cos(N * aw + 1.7 * sin(a * 5.0));
                float body = pow(lobe, 2.2);
                // Fine strands inside each tendril, wobbling on their own.
                float aw2 = aw + 0.05 * sin(d * 30.0 - t * 4.0 + a * 11.0);
                float strands = 0.6 + 0.4 * fxNoise3(float3(dir * 40.0 + aw2 * 3.0, d * 3.0 - t * 0.8));
                float fine = 0.7 + 0.3 * fxNoise3(float3(dir * 14.0, d * 6.0 - t * 1.2));
                float falloff = exp(-d / max(reach, 0.02)) * exp(-d * d / max(reach * reach * 4.0, 1e-4));
                // A halo of loose wisps between the tendrils.
                float wisps = 0.18 * exp(-d / (reach * 0.6)) * (0.6 + 0.4 * fxNoise3(float3(dir * 6.0, d * 4.0 - t)));
                return (body * strands * fine * (1.0 + 0.6 * kick) + wisps) * falloff;
            }

            fragment float4 flameSunFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float t = u.resTime.z * mix(0.45, 1.0, intensity);
                float kick = u.env.x * intensity;
                float snare = u.env.y * intensity;
                float hat = u.env.z * intensity;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.35);
                float highs = bandAt(spectrum, 0.8);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float r = length(p) + 1e-5;
                float2 dir = p / r;
                float a = atan2(p.y, p.x);
                float R = 0.42 * (1.0 + 0.07 * bass + 0.05 * kick + 0.04 * drop);

                float3 col = float3(0.0);
                float heat = 0.0;

                // ---- The corona: flame tendrils, two layers turning against each other -----------------------------------
                if (r > R * 0.9) {
                    // Each tendril's reach follows the spectrum band at its angle (mirrored so there is no seam).
                    float band = bandAt(spectrum, abs(fract(a / 6.2831853 + 0.5) * 2.0 - 1.0) * 0.8 + 0.05);
                    float reach = R * (0.22 + 0.4 * band + 0.3 * kick + 0.3 * drop + 0.1 * energy);
                    float spin = t * 0.04;
                    float2 d1 = float2(cos(a + spin), sin(a + spin));
                    float tA = fsTendrils(d1, a + spin, r, R, t, reach, kick);
                    float2 d2 = float2(cos(a - spin * 1.3 + 0.07), sin(a - spin * 1.3 + 0.07));
                    float tB = fsTendrils(d2 * 1.1, a - spin * 1.3 + 0.07, r, R, t * 1.1 + 5.0, reach * 0.75, kick);
                    heat += tA * 1.1 + tB * 0.55;
                    // Tight limb glow and a broad soft bloom.
                    float d = r - R;
                    heat += exp(-max(d, 0.0) / (R * 0.05)) * 0.7 + exp(-max(d, 0.0) / (R * 0.4)) * 0.18 * (1.0 + kick);
                    // The snare's shock ring.
                    float ringR = R * (1.1 + 1.6 * (1.0 - snare));
                    heat += snare * 0.8 * exp(-abs(r - ringR) / (R * 0.04)) * (0.6 + 0.4 * fxNoise3(float3(dir * 8.0, t)));
                }

                // ---- The disc: a molten, veined sphere with a white-hot core bursting outward ----------------------------
                if (r < R * 1.02) {
                    float rr = r / R;
                    float z = sqrt(max(1.0 - rr * rr, 0.0));
                    float3 sph = float3(p / R, z);
                    // Slow rotation about the vertical axis.
                    float ca = cos(t * 0.05);
                    float sa = sin(t * 0.05);
                    float3 q = float3(ca * sph.x + sa * sph.z, sph.y, -sa * sph.x + ca * sph.z);
                    float churn = t * (0.12 + 0.25 * mids);
                    float3 w = q * 3.0 + float3(fxFbm3(q * 2.5 + churn, 3), fxFbm3(q * 2.5 - churn + 7.0, 3), 0.0) * 1.4;
                    float cells = fxFbm3(w + float3(0.0, 0.0, churn * 0.5), 4);
                    float veins = fxRidge(fxFbm3(w * 1.8 + 3.0, 4), 0.82);
                    float fineVeins = fxRidge(fxFbm3(w * 4.5 - 2.0, 3), 0.88);
                    float surface = 0.18 + 0.22 * cells + 0.5 * veins + 0.22 * fineVeins;
                    // Radial bursts out of the core.
                    float burst = pow(fxNoise3(float3(dir * 9.0, rr * 2.0 - t * 1.5)), 3.0) * exp(-rr * 3.0) * 1.2;
                    float core = exp(-rr * rr * 60.0) * (1.6 + 1.2 * kick) + exp(-rr * 6.0) * 0.25;
                    float limb = 0.55 + 0.45 * pow(z, 0.5);
                    float disc = (surface * limb + burst * (1.0 + 0.8 * kick) + core) * (0.85 + 0.25 * bass + 0.25 * kick);
                    float edge = smoothstep(1.02, 0.985, rr);
                    heat = mix(heat, disc + 0.1, edge);
                }

                col = fsFire(heat * (0.8 + 0.2 * energy));
                // With a palette look active the same heat runs through the palette (c0 embers, c1 flame, c2 the hottest),
                // still burning to white in the core.
                float hx = saturate(heat * 0.6);
                float3 pal = hx < 0.5 ? mix(u.c0.rgb, u.c1.rgb, hx * 2.0) : mix(u.c1.rgb, u.c2.rgb, hx * 2.0 - 1.0);
                pal = pal * max(dot(col, float3(0.3, 0.5, 0.2)), 0.0) * 1.6 + float3(1.0) * smoothstep(1.2, 2.2, heat) * 0.6;
                col = mix(col, pal, u.extra.y);
                float3 tint = mix(float3(1.0), mix(u.c1.rgb, u.c2.rgb, 0.5) * 1.4, u.extra.y);

                // ---- Embers drifting outward, and far stars ---------------------------------------------------------------
                for (int layer = 0; layer < 2; layer++) {
                    float fl = float(layer);
                    float2 c;
                    float h;
                    float cs = layer == 0 ? 0.05 : 0.11;
                    float2 q = p * (1.0 - 0.06 * fract(t * (0.05 + 0.03 * fl))) + fl * 3.7;
                    if (fxCell(q + dir * t * (0.03 + 0.02 * fl), cs, 23.0 + fl * 9.0, layer == 0 ? 0.28 : 0.2, c, h)) {
                        float size = (layer == 0 ? 0.0025 : 0.005) * (0.5 + h);
                        float e = exp(-dot(q + dir * t * (0.03 + 0.02 * fl) - c, q + dir * t * (0.03 + 0.02 * fl) - c) / (size * size));
                        float tw = 0.4 + 0.6 * sin(t * (1.0 + 3.0 * h) + h * 50.0) * 0.5 + 0.5 + 0.9 * hat + 0.5 * highs;
                        float nearSun = exp(-max(r - R, 0.0) * 1.2);
                        col += fsFire(0.55 + 0.3 * h) * tint * e * tw * (0.25 + 0.75 * nearSun) * (layer == 0 ? 0.9 : 0.5);
                    }
                }

                col = fxFlash(col, u, 0.35);
                col = fxTonemap(col, 1.15);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
