#if canImport(Metal)
    /// Pitch wheel (Metal): the 12 pitch classes as glass petals around a lit core, C at the top and clockwise in
    /// semitones. A petal rests as a dim glass track and grows outward with the strength of its class, cylinder-lit
    /// in its own hue and hot at the tip, with a bead at the end and a dot for each class on an outer ring (hollow for
    /// the sharps). The classes sounding strongly are joined by a luminous chord polygon; the key is a bright outline
    /// around the tonic's petal with a spoke to the center, scaled by how sure the estimate is, and the center ball takes
    /// the tonic's color. Behind it a slow mandala of rings turns, with dust. The bass swells the core and the inner
    /// glow, the highs sparkle on the tips, a kick pushes the petals out and throws a ring, a snare a wide one, the beat a
    /// faint one. The Metal port of the Canvas `pitchWheel`.
    enum PitchWheelMetalShader {
        static let source = #"""
            static float pitchWheelMetalAngle(int pc) {
                return (float(pc) / 12.0 - 0.25) * 6.2831853;
            }

            fragment float4 pitchWheelMetalFragment(
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
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);
                float beatPhase = fract(beats);
                float beatPulse = pow(1.0 - beatPhase, 3.0);
                float3 light = fxKeyLight();
                float px = u.resTime.y;

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.02 * intensity;
                float r = length(p) + 1e-4;
                float a = atan2(p.y, p.x);

                float tonic = aux[108];
                float confidence = aux[109];
                float keyed = (confidence > 0.2 && tonic >= 0.0) ? 1.0 : 0.0;
                float inner = 0.22;
                float base = 0.34;
                float reach = 0.5 * (1.0 + 0.06 * kick * intensity);
                float gapHalf = 0.2268;
                float3 deep = mix(u.c0.rgb, u.c1.rgb, 0.5);

                // Far: the dark glass, a glow that follows the bass, a slow mandala of rings and spokes, and dust.
                float3 col = float3(0.003, 0.005, 0.012) + deep * exp(-r * r * 1.4) * (0.03 + 0.06 * energy + 0.14 * bass + 0.08 * kick);
                {
                    float spin = travel * 0.01;
                    float spokes = pow(0.5 + 0.5 * cos((a + spin) * 24.0), 14.0) * smoothstep(0.35, 1.0, r) * smoothstep(1.7, 1.0, r);
                    float rings = exp(-pow((r - 0.95) * px * 0.4, 2.0)) + exp(-pow((r - 1.15) * px * 0.4, 2.0)) * 0.6;
                    col += u.c0.rgb * (spokes * 0.025 + rings * 0.035) * (0.6 + 0.8 * energy + 0.6 * highs);
                }
                col += mix(float3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(float2(in.uv.x * aspect, in.uv.y - time * 0.01), 26.0, 14.0, time) * (0.2 + 0.8 * highs);

                // Rings leaving the core: a faint one each beat, a bright one on a kick, a wide one on a snare.
                col += u.c0.rgb * exp(-pow((r - (0.3 + beatPhase * 1.2)) * px * 0.3, 2.0)) * 0.05 * pow(1.0 - beatPhase, 2.0);
                col += mix(u.c1.rgb, float3(1.0), 0.3) * exp(-pow((r - (0.4 + (1.0 - kick) * 0.7)) / 0.012, 2.0)) * kick * kick * 0.4;
                col += mix(u.c2.rgb, float3(1.0), 0.4) * exp(-pow((r - (0.5 + (1.0 - snare) * 0.9)) / 0.016, 2.0)) * snare * snare * 0.3;

                // The petals.
                float pcF = (a / 6.2831853 + 0.25) * 12.0;
                pcF -= 12.0 * floor(pcF / 12.0);
                float nearest = floor(pcF + 0.5);
                int pc = int(nearest) % 12;
                float d = (pcF - nearest) * 0.5235988;
                float lx = d / gapHalf;
                float value = clamp(aux[64 + pc], 0.0, 1.0);
                float3 tint = paletteAt(u, float(pc) / 12.0);
                tint = tint * (1.0 + 0.45 * (tint / max(dot(tint, float3(0.333)), 0.05) - 1.0));
                float wedge = smoothstep(1.0, 0.9, abs(lx));
                bool isTonic = keyed > 0.5 && int(tonic + 0.5) == pc;
                {
                    float z = sqrt(max(1.0 - lx * lx, 0.0));
                    float2 lit = fxLight(float3(lx * 1.0, -0.3, z), light, 26.0);
                    // The resting track.
                    float track = smoothstep(inner - 0.004, inner + 0.004, r) * smoothstep(base + 0.004, base - 0.004, r) * wedge;
                    float3 trackCol = (isTonic ? u.c2.rgb * 0.25 : float3(0.35, 0.4, 0.5) * 0.07) * (0.4 + lit.x);
                    col += trackCol * track + tint * 0.03 * track;
                    // The grown petal.
                    float outer = base + reach * value;
                    float t = clamp((r - inner) / max(outer - inner, 1e-3), 0.0, 1.0);
                    float body = smoothstep(inner - 0.004, inner + 0.004, r) * smoothstep(outer + 0.006, outer - 0.006, r) * wedge * step(0.02, value);
                    float3 petal = tint * (0.06 + 1.5 * lit.x) * (0.4 + 1.3 * pow(t, 1.3)) * (0.5 + 1.0 * value) * (1.0 - 0.35 * abs(lx));
                    petal += mix(tint, float3(1.0), 0.7) * pow(t, 6.0) * value * 0.8;
                    petal += float3(1.0) * lit.y * 0.35 * value;
                    col += petal * body;
                    // Bloom around the petal.
                    float2 q = float2(r - clamp(r, inner, outer), d * r);
                    col += tint * exp(-dot(q, q) * 90.0) * value * value * (0.2 + 0.2 * bass) * (1.0 - body) * smoothstep(0.0, 0.1, value);
                    // The tip bead.
                    float2 tip = float2(r - outer, d * r);
                    col += mix(tint, float3(1.0), 0.65) * exp(-dot(tip, tip) * 5000.0) * step(0.05, value) * (0.7 + 1.4 * highs * hat + 0.4 * kick);
                    // The key: an outline around the tonic's petal.
                    if (isTonic) {
                        float edge = exp(-pow(max(abs(lx) - 1.0, 0.0) * 0.0 + (abs(lx) - 0.95) * gapHalf * r * px * 0.5, 2.0));
                        float rim = exp(-pow((r - (base + reach)) * px * 0.5, 2.0)) * step(abs(lx), 1.0);
                        float rimIn = exp(-pow((r - inner) * px * 0.5, 2.0)) * step(abs(lx), 1.0);
                        col += mix(u.c2.rgb, float3(1.0), 0.3) * (edge * step(inner, r) * step(r, base + reach) + rim + rimIn) * confidence * 0.9;
                    }
                }

                // The dots on the outer ring: hollow for the sharps, lit by their class, the tonic's larger.
                {
                    float ringR = base + reach + 0.1;
                    for (int k = 0; k < 12; k++) {
                        float ang = pitchWheelMetalAngle(k);
                        float2 dp = p - ringR * float2(cos(ang), sin(ang));
                        float level = clamp(aux[64 + k], 0.0, 1.0);
                        bool sharp = k == 1 || k == 3 || k == 6 || k == 8 || k == 10;
                        float big = (keyed > 0.5 && int(tonic + 0.5) == k) ? 1.5 : 1.0;
                        float dd = length(dp);
                        float radius = 0.014 * big;
                        float dot0 = sharp ? exp(-pow((dd - radius) / 0.004, 2.0)) : smoothstep(radius, radius * 0.5, dd);
                        float3 dt = paletteAt(u, float(k) / 12.0);
                        col += mix(float3(0.35, 0.4, 0.5) * 0.6, dt * 1.5 + float3(0.4), level) * dot0 * (0.7 + 0.8 * level);
                        col += dt * exp(-dd * 24.0) * level * 0.1;
                    }
                    col += u.c0.rgb * exp(-pow((r - ringR) * px * 0.5, 2.0)) * 0.035 * (0.6 + 0.8 * energy);
                }

                // The chord polygon: the classes sounding strongly, joined in order around the wheel.
                {
                    float2 first = float2(0.0);
                    float2 prev = float2(0.0);
                    bool have = false;
                    float line = 1e3;
                    for (int k = 0; k < 12; k++) {
                        float level = clamp(aux[64 + k], 0.0, 1.0);
                        if (level < 0.45) continue;
                        float ang = pitchWheelMetalAngle(k);
                        float2 pt = (base + reach * level) * float2(cos(ang), sin(ang));
                        if (have) line = min(line, fxSegment(p, prev, pt)); else first = pt;
                        prev = pt;
                        have = true;
                    }
                    if (have && length(prev - first) > 1e-3) line = min(line, fxSegment(p, prev, first));
                    float2 beam = fxBeam(line, 0.0035);
                    col += (mix(u.c2.rgb, float3(1.0), 0.5) * beam.x * 0.9 + u.c1.rgb * beam.y * 0.6) * (0.7 + 0.5 * kick) * (have ? 1.0 : 0.0);
                }

                // The center: a glass ball in the tonic's color (the palette's own when there is no key), swelling with the
                // bass, with a spoke out to the tonic.
                {
                    float ballR = 0.17 * (1.0 + 0.1 * bass + 0.08 * kick);
                    float2 rel = p / ballR;
                    float3 ballTint = keyed > 0.5 ? paletteAt(u, tonic / 12.0) : mix(u.c1.rgb, u.c0.rgb, 0.5);
                    if (dot(rel, rel) < 1.0) {
                        float3 ball = fxBall(rel, light, ballTint);
                        float plasma = fxFbm3(float3(rel * 2.0 + float2(cos(time * 0.25), sin(time * 0.25)) * 0.5, time * 0.3), 3);
                        ball *= 0.55 + 0.9 * plasma;
                        ball += ballTint * (0.1 + 0.3 * bass + 0.2 * kick) * sqrt(max(1.0 - dot(rel, rel), 0.0));
                        col = mix(col, ball, smoothstep(1.0, 0.94, length(rel)));
                    }
                    col += ballTint * exp(-max(r - ballR, 0.0) * 16.0) * (0.06 + 0.2 * bass + 0.1 * kick) * smoothstep(ballR * 0.5, ballR, r);
                    if (keyed > 0.5) {
                        float ang = pitchWheelMetalAngle(int(tonic + 0.5));
                        float2 tipPt = (base + 0.04) * float2(cos(ang), sin(ang));
                        float2 start = ballR * 1.05 * float2(cos(ang), sin(ang));
                        float2 spoke = fxBeam(fxSegment(p, start, tipPt), 0.003);
                        col += u.c2.rgb * (spoke.x * 0.6 + spoke.y * 0.4) * confidence * (0.6 + 0.6 * beatPulse);
                    }
                }

                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
