#if canImport(Metal)
    /// A night beach whose breakers glow: one wave breaks per beat, plankton sparks in the swash. Promoted from the SoundGallery drop-in plugin `biolum.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum BioluminescentSeaShader {
        static let source = #"""
            // title: Bioluminescent sea
            // fragment: bioSeaFragment

            // A night beach where the surf glows: electric-blue breakers roll in one per beat, curl into lines of light and
            // spill glowing foam that slides up the wet sand and mirrors in it, under a sky of stars and a faint galaxy. Plankton
            // sparkle in the dark water with the hats; each stretch of shoreline glows with one spectrum band; a kick lights the
            // whole surf, a snare bursts the breaking crest, the drop sets the sea ablaze; bass swells the waves.

            struct BioCam {
                float3 ro;
                float3 fw;
                float3 rt;
                float3 up;
            };

            static float3 bioSky(float3 rd, float t, float hat, constant IntenseUniforms &u) {
                float h = max(rd.y, 0.0);
                float3 sky = mix(float3(0.012, 0.02, 0.05), float3(0.002, 0.003, 0.012), sqrt(h));
                sky += float3(0.03, 0.05, 0.09) * exp(-h * 18.0);  // horizon airglow
                float2 sp = rd.xz / max(rd.y + 0.15, 0.05);
                // A faint galaxy band.
                float band = exp(-pow((sp.x * 0.6 + sp.y * 0.35 - 0.2) * 1.4, 2.0));
                sky += mix(float3(0.06, 0.05, 0.09), u.c2.rgb * 0.08, 0.3) * band * fxFbm3(float3(sp * 2.0, 1.0), 4) * smoothstep(0.02, 0.2, h);
                for (int layer = 0; layer < 2; layer++) {
                    float2 c;
                    float hs;
                    float cs = layer == 0 ? 0.035 : 0.09;
                    float2 q = sp + float(layer) * 7.1;
                    if (fxCell(q, cs, 11.0 + float(layer) * 5.0, layer == 0 ? 0.35 : 0.2, c, hs)) {
                        float size = cs * (layer == 0 ? 0.06 : 0.09) * (0.5 + hs);
                        float d = length(q - c);
                        float tw = 0.65 + 0.35 * sin(t * (1.0 + 3.0 * hs) + hs * 40.0) + 0.3 * hat;
                        sky += float3(0.85, 0.9, 1.0) * exp(-d * d / (size * size)) * tw * (0.5 + hs) * smoothstep(0.0, 0.08, h);
                    }
                }
                return sky;
            }

            fragment float4 bioSeaFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float t = u.resTime.z * mix(0.45, 1.0, intensity);
                float beats = u.resTime.w;
                float kick = u.env.x * intensity;
                float snare = u.env.y * intensity;
                float hat = u.env.z * intensity;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float2 sp = float2(p.x, -p.y);
                float px = 2.0 / max(u.resTime.y, 1.0);
                float2 pix = in.uv * u.resTime.xy;
                float dither = fract(52.9829189 * fract(dot(pix, float2(0.06711056, 0.00583715))));

                BioCam cam;
                cam.ro = float3(0.0, 1.1, 2.0);
                cam.fw = normalize(float3(0.0, -0.16, -1.0));
                cam.rt = normalize(cross(cam.fw, float3(0.0, 1.0, 0.0)));
                cam.up = cross(cam.rt, cam.fw);
                float3 rd = normalize(cam.fw * 1.9 + cam.rt * sp.x + cam.up * sp.y);

                float3 glowTint = mix(float3(0.08, 0.55, 1.0), mix(u.c1.rgb, u.c2.rgb, 0.4) * 1.2, u.extra.y);
                float3 glowHot = mix(glowTint, float3(0.75, 0.95, 1.0), 0.45);
                float3 col = bioSky(rd, t, hat, u);

                if (rd.y < -0.002) {
                    float tt = -cam.ro.y / rd.y;
                    float3 P = cam.ro + rd * tt;
                    float2 xz = P.xz;
                    float foot = tt * px * 1.2;  // world size of a pixel here
                    // The shoreline wanders; the sea is beyond it (negative z), the beach in front.
                    float shoreZ = -1.2 + 0.35 * sin(xz.x * 0.35 + 1.3) + 0.2 * sin(xz.x * 0.9 + 4.0);
                    float dz = shoreZ - xz.y;  // > 0 out at sea
                    // The band each stretch of shore listens to (mirrored so there is no seam).
                    float lane = abs(fract(xz.x * 0.045 + 0.5) * 2.0 - 1.0);
                    float band = bandAt(spectrum, lane * 0.8 + 0.05);
                    float lift = (1.0 + 1.6 * kick + 0.9 * drop) * (0.55 + 0.25 * energy + 0.3 * bass) * mix(0.5, 1.0, intensity);

                    // ---- Breakers: one arrives per beat, curling into a line of light near the shore -------------------
                    float k = 0.8;
                    float wob = 0.35 * (fxNoise3(float3(xz.x * 0.35, dz * 0.2, 0.0)) - 0.5) + 0.12 * sin(xz.x * 1.3 + t * 0.4);
                    float phase = dz * k + beats + wob;
                    float n = floor(phase);
                    float f = fract(phase);
                    float hn = hash11(n * 3.17);
                    float breaking = smoothstep(7.0, 1.2, dz) * smoothstep(-0.1, 0.35, dz);
                    // A breaker is a broken line, not a ruler: gaps open along it.
                    float gaps = smoothstep(0.25, 0.6, fxNoise3(float3(xz.x * 0.4, n * 1.7, 2.0)) + 0.35 * breaking);
                    float w = max(0.025, foot * k * 1.5);
                    float curl = exp(-f / w) * smoothstep(0.0, w * 0.5, f) + exp(-(1.0 - f) / (w * 0.5)) * 0.4;
                    float foamTex = fxFbm3(float3(xz * float2(1.4, 2.2) + float2(0.0, n * 3.0), t * 0.25), 4);
                    float foam = smoothstep(0.35, 0.75, foamTex) * exp(-f * 3.5) * smoothstep(0.0, 0.08, f);
                    float burst = snare * exp(-f / (w * 2.0)) * smoothstep(0.55, 0.9, fxNoise3(float3(xz * 3.0, t * 2.0)));
                    float sea = step(0.0, dz);
                    float glow = (curl * 1.7 + foam * 0.9 + burst * 2.0) * breaking * gaps * (0.5 + 0.5 * hn)
                        * (0.45 + 1.1 * band) * lift * sea;

                    // The water itself: swells reflect the sky; plankton sparkle in it.
                    float sw = 0.07 * (1.0 + 0.6 * bass);
                    float2 g = float2(
                        sw * cos(xz.y * 1.7 + xz.x * 0.3 + t * 1.1) * 0.3 + sw * cos(xz.x * 2.3 - t * 0.7) * 0.5,
                        sw * cos(xz.y * 1.7 + xz.x * 0.3 + t * 1.1) * 1.7 + 0.03 * cos(xz.y * 4.1 - t * 1.9) * 4.1);
                    float3 nrm = normalize(float3(-g.x, 1.0, -g.y) + float3(0.0, max(foot * 2.0, 0.0), 0.0));
                    float3 refl = reflect(rd, nrm);
                    float fres = 0.02 + 0.98 * pow(1.0 - max(dot(-rd, nrm), 0.0), 5.0);
                    float3 water = float3(0.002, 0.006, 0.012) + bioSky(refl, t, 0.0, u) * fres * 0.8;
                    float2 c;
                    float hs;
                    float3 plankton = float3(0.0);
                    if (fxCell(xz * float2(1.0, 1.0), 0.22, 31.0, 0.5, c, hs)) {
                        float size = max(0.012 * (0.5 + hs), foot * 0.7);
                        float d = length(xz - c);
                        float tw = pow(0.5 + 0.5 * sin(t * (2.0 + 4.0 * hs) + hs * 60.0), 6.0) * (0.3 + 1.6 * hat + 0.8 * highs);
                        plankton = glowHot * exp(-d * d / (size * size)) * tw * smoothstep(9.0, 0.5, dz) * 0.8;
                    }
                    // Behind each breaker the water keeps a faint glow, fading out to sea.
                    float wake = exp(-f * 1.5) * 0.12 * breaking * (0.4 + band) * lift;

                    // ---- The beach: wet sand mirrors the surf, the swash slides up it ---------------------------------
                    float wet = smoothstep(-2.2, 0.0, dz);
                    float3 sand = mix(float3(0.012, 0.011, 0.01), float3(0.004, 0.005, 0.008), wet);
                    // The swash: a sheet of glowing water runs up the sand after each breaker and drains back.
                    float run = fract(beats + 0.15);
                    float reach = -1.5 * sin(3.14159265 * min(run * 1.4, 1.0)) * (0.7 + 0.3 * bass);
                    float swashEdge = exp(-abs(dz - reach) / max(0.04, foot * 1.5)) * smoothstep(0.0, -0.05, dz);
                    float swashSheet = smoothstep(reach - 0.02, reach + 0.25, dz) * smoothstep(0.1, -0.02, dz)
                        * smoothstep(0.3, 0.7, fxNoise3(float3(xz * 2.5, t * 0.5)));
                    float swash = (swashEdge * 1.1 + swashSheet * 0.35) * (1.0 - run * 0.7) * (0.4 + band) * lift;
                    // Mirror: the bright line just offshore reflects in the wet sand.
                    float mirror = exp(dz * 1.6) * wet * (0.25 + 0.6 * band) * lift * 0.35;
                    float3 beach = sand + glowTint * (swash + mirror) + bioSky(reflect(rd, float3(0.0, 1.0, 0.0)), t, 0.0, u) * wet * 0.15;

                    float3 ground = mix(beach, water + glowTint * wake + plankton, smoothstep(-0.03, 0.03, dz));
                    ground += mix(glowTint, glowHot, smoothstep(0.6, 1.6, glow)) * glow;
                    // Distance haze toward the horizon.
                    float haze = 1.0 - exp(-tt * 0.04);
                    col = mix(ground, bioSky(float3(rd.x, 0.002, rd.z), t, 0.0, u), haze);
                }

                col += (dither - 0.5) / 255.0;
                col = fxFlash(col, u, 0.3);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.15);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
