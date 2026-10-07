#if canImport(Metal)
    /// Halo (Metal): a radial spectrum around a glossy, breathing core. The 64 bands fan out as lit needles on both
    /// sides of a slowly turning axis (one turn per four bars, locked to the song), bass nearest the axis and highs at
    /// the back, each a rounded rod with a diffuse side, a white specular and a hot tip, a peak-hold tick beyond it and a
    /// bloom that follows the spectrum's own envelope. The core is a shaded ball with a swirling plasma skin that swells
    /// on the kick; the waveform wraps just inside it as a neon ring that splits into two fringes on a glitch. Four
    /// rings leave the core across every four beats, a snare throws a bright one, dust flies out of the center and
    /// grows, and sparks are shed from the tips on the highs. The Metal port of the Canvas `halo`.
    enum HaloMetalShader {
        static let source = #"""
            static float haloMetalWrap(float a) {
                return a - 6.2831853 * floor(a / 6.2831853 + 0.5);
            }

            // Dust flying out of the center and growing, in two zoom layers half a cycle apart.
            static float3 haloMetalDust(float2 p, float zoom, float seed, float density, float time, float3 tint) {
                FxZoomLayer layer = fxZoomLayer(p, zoom);
                float2 c;
                float h;
                if (!fxCell(layer.q, 0.16, seed, density, c, h)) return float3(0.0);
                c += 0.02 * float2(sin(time * 1.3 + h * 6.28), cos(time * 1.1 + h * 9.0));
                float screenDistance = length(c) * layer.scale;
                float reach = smoothstep(0.2, 0.5, screenDistance) * smoothstep(1.8, 1.2, screenDistance);
                float2 rel = layer.q - c;
                float spark = exp(-dot(rel, rel) * 11000.0 / (0.5 + h));
                return tint * spark * layer.fade * reach;
            }

            fragment float4 haloMetalFragment(
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
                float mids = bandAt(spectrum, 0.4);
                float highs = bandAt(spectrum, 0.8);
                float beatPhase = fract(beats);
                float beatPulse = pow(1.0 - beatPhase, 3.0);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.03 * intensity;
                float r = length(p) + 1e-4;
                float a = atan2(p.y, p.x);
                float3 light = fxKeyLight();

                float pulse = 1.0 + 0.12 * kick * intensity + 0.03 * beatPulse + 0.07 * bass * intensity;
                float coreR = 0.30 * pulse;
                float inner = coreR + 0.04;
                float maxLength = 0.46 * (1.0 + 0.25 * drop);
                float rotation = beats / 16.0 * 6.2831853 - 1.5707963;
                float3 col = float3(0.002, 0.004, 0.012) + mix(u.c0.rgb, u.c1.rgb, 0.5) * exp(-r * r * 1.6) * (0.03 + 0.05 * energy + 0.07 * kick);

                // Far: dim stars and dust flying out of the center, growing as they come.
                col += mix(float3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(p, 15.0, 4.0, time) * 0.5;
                float3 dustTint = mix(u.c1.rgb, float3(1.0), 0.5) * (0.5 + 0.9 * highs + 0.5 * hat);
                col += haloMetalDust(p, fract(travel * 0.08), 3.0, 0.3, time, dustTint) * 0.6;
                col += haloMetalDust(p, fract(travel * 0.08 + 0.5), 3.5, 0.3, time, dustTint) * 0.6;

                // Beat rings: one leaves the core every beat and fades over four beats; a snare throws a brighter one.
                for (int k = 0; k < 4; k++) {
                    float age = (beatPhase + float(k)) / 4.0;
                    float ringR = inner + age * maxLength * 1.5;
                    col += u.c2.rgb * exp(-pow((r - ringR) * 90.0, 2.0)) * (1.0 - age) * (1.0 - age) * 0.28;
                }
                float shockR = inner + (1.0 - snare) * 1.3;
                col += mix(u.c1.rgb, float3(1.0), 0.4) * exp(-pow((r - shockR) / (0.012 + 0.04 * snare), 2.0)) * snare * 0.7;

                // Mid: the spectrum as lit needles on both sides of the axis.
                float spread = abs(haloMetalWrap(a - rotation));
                float bandPos = spread / 3.1415927 * 64.0;
                int i = clamp(int(bandPos), 0, 63);
                float f = fract(bandPos);
                float v = pow(spectrum[i], 0.8);
                float length_ = max(0.012, v * maxLength);
                float lateral = (f - 0.5) * 3.1415927 / 64.0 * r;
                float s = (r - inner) / length_;
                float halfW = 0.0052 + 0.0032 * clamp(s, 0.0, 1.0);
                float3 hue = paletteAt(u, spread / 3.1415927 * 0.66);
                {
                    float lx = lateral / halfW;
                    float tipEnd = inner + length_;
                    float dTip = max(r - tipEnd, 0.0);
                    float outside = max(abs(lateral) - halfW * (1.0 - 0.35 * pow(clamp(s, 0.0, 1.0), 3.0)), 0.0);
                    if (r > inner * 0.98) {
                        // The rod: a rounded body lit from the left, brighter toward the hot tip.
                        float inside = step(r, tipEnd) * smoothstep(1.1, 0.75, abs(lx));
                        float z = sqrt(max(1.0 - lx * lx, 0.0));
                        float2 lit = fxLight(float3(lx, 0.0, z), light, 22.0);
                        float3 body = mix(hue * 0.5, mix(hue, float3(1.0), 0.45), clamp(s, 0.0, 1.0)) * (0.3 + 0.9 * lit.x);
                        col += (body * 1.5 + float3(1.0) * lit.y * 0.5) * inside * (0.5 + 0.8 * v);
                        // The tip's glow and the bloom along the rod.
                        float2 beam = fxBeam(length(float2(outside, dTip)), 0.005);
                        col += (hue * beam.y * 1.5 + mix(hue, float3(1.0), 0.7) * beam.x * 0.8) * (0.4 + 1.1 * v);
                        // The peak-hold tick, floating beyond.
                        float peakEnd = inner + pow(aux[i], 0.8) * maxLength + 0.018;
                        float tick = exp(-pow((r - peakEnd) * 200.0, 2.0)) * smoothstep(1.2, 0.5, abs(lx)) * step(0.01, aux[i]);
                        col += float3(1.0) * tick * 0.8;
                    }
                    // The envelope bloom: a soft halo that follows the whole spectrum around the ring.
                    float env = pow(bandAt(spectrum, clamp(bandPos / 64.0, 0.0, 1.0)), 0.8);
                    float envEnd = inner + env * maxLength;
                    col += hue * exp(-max(r - envEnd, 0.0) * 8.0) * smoothstep(inner * 0.9, inner * 1.3, r) * env * 0.14 * (1.0 + 0.8 * kick);
                }

                // Near: sparks shed from the tips on the highs, a few at a time.
                {
                    float2 sp = float2(cos(a), sin(a)) * r;
                    float cellA = floor(spread / 3.1415927 * 24.0 + 0.5);
                    float shed = hash21(float2(cellA, floor(travel * 1.3 + hash11(cellA) * 4.0)));
                    float t = fract(travel * 1.3 + hash11(cellA) * 4.0);
                    float lenA = pow(spectrum[clamp(int(cellA / 24.0 * 63.0), 0, 63)], 0.8) * maxLength;
                    float sparkR = inner + lenA + t * 0.22;
                    float sparkA = rotation + (shed > 0.5 ? 1.0 : -1.0) * cellA / 24.0 * 3.1415927;
                    float2 sc = float2(cos(sparkA), sin(sparkA)) * sparkR;
                    float on = step(0.55 - 0.3 * highs - 0.2 * hat, hash11(cellA * 1.7 + floor(travel * 1.3) * 3.1));
                    col += mix(u.c2.rgb, float3(1.0), 0.7) * exp(-dot(p - sc, p - sc) * 9000.0) * (1.0 - t) * on * 0.9;
                }

                // The core: a glossy ball whose skin is swirling plasma, jumping on the kick.
                {
                    float2 rel = p / coreR;
                    float d2 = dot(rel, rel);
                    if (d2 < 1.2) {
                        float z = sqrt(max(1.0 - d2, 0.0));
                        float3 n = float3(rel, z);
                        float2 lit = fxLight(n, light, 20.0);
                        float plasma = fxFbm3(float3(rel * 2.2 + float2(cos(time * 0.2), sin(time * 0.2)) * 0.6, time * 0.25), 3);
                        float3 tint = mix(u.c1.rgb, u.c0.rgb, plasma);
                        float3 skin = tint * (0.08 + 0.55 * lit.x) * (0.35 + 1.5 * plasma * plasma) + float3(1.0) * lit.y * 0.55;
                        skin += mix(tint, float3(1.0), 0.6) * (0.2 * kick + 0.05 * energy + 0.3 * bass) * z;
                        float rim = smoothstep(0.6, 1.0, sqrt(d2));
                        skin += u.c2.rgb * rim * (0.5 + 0.5 * energy);
                        col = mix(col, skin, smoothstep(1.02, 0.94, sqrt(d2)));
                    }
                    col += mix(u.c1.rgb, u.c0.rgb, 0.5) * exp(-max(r - coreR, 0.0) * 14.0) * 0.12 * (0.6 + 0.6 * kick + 0.8 * bass);

                    // The oscilloscope ring: the waveform wrapped just inside the core.
                    float turn = fract((a - rotation) / 6.2831853);
                    float w = wave[int(turn * 511.0)];
                    float ringR = coreR * (0.78 + 0.32 * w * 0.8);
                    float2 beam = fxBeam(abs(r - ringR), 0.004);
                    float chroma = u.fx.y;
                    float3 ringTint = mix(u.c2.rgb, float3(1.0), 0.75);
                    col += (u.c2.rgb * beam.y * 1.3 + ringTint * beam.x) * smoothstep(coreR * 1.08, coreR * 0.9, r);
                    if (chroma > 0.02) {
                        float2 pl = p - float2(chroma * 0.02, 0.0);
                        float2 pr = p + float2(chroma * 0.02, 0.0);
                        float wl = wave[int(fract((atan2(pl.y, pl.x) - rotation) / 6.2831853) * 511.0)];
                        float wr = wave[int(fract((atan2(pr.y, pr.x) - rotation) / 6.2831853) * 511.0)];
                        col += u.c0.rgb * fxBeam(abs(length(pl) - coreR * (0.78 + 0.26 * wl)), 0.004).x * 0.6;
                        col += u.c2.rgb * fxBeam(abs(length(pr) - coreR * (0.78 + 0.26 * wr)), 0.004).x * 0.6;
                    }
                }

                col = fxFlash(col, u, 0.25);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
