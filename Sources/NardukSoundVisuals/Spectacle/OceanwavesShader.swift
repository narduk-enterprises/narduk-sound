#if canImport(Metal)
    /// Ocean waves, a shader-pack look: layered Gerstner swells seen low from the side.
    ///
    /// Appended to `ShaderPackSource.source`. Helpers are prefixed `ocean` so they do not collide with the pack.
    /// `c0` is the deep water, `c1` the lit faces, `c2` the foam and highlights. A warm moon sits in the sky.
    /// Bass lifts the swells and breaks the crests, mids set the speed and how many layers roll, highs add glints
    /// and ripples, a kick pushes one swell through every layer, and `dropAmount` steepens the sea and adds foam.
    /// Calm scales the clock by 0.4 and drops the kick swell. No full-screen flash.
    enum OceanwavesShader {
        static let source = #"""
            // MARK: Ocean waves

            struct OceanSample {
                float h;
                float crest;
            };

            static float oceanNoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                float a = hash21(i);
                float b = hash21(i + float2(1.0, 0.0));
                float c = hash21(i + float2(0.0, 1.0));
                float d = hash21(i + float2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }

            static float oceanFbm(float2 p) {
                float v = 0.0;
                float a = 0.55;
                for (int oct = 0; oct < 3; oct++) {
                    v += a * oceanNoise(p);
                    p = p * 2.05 + float2(1.7, 9.2);
                    a *= 0.5;
                }
                return v;
            }

            static OceanSample oceanSample(
                float x, float wt, float amp, float k, float steep, float phase
            ) {
                float ph0 = k * x - wt + phase;
                float s = x - steep * 0.04 * cos(ph0);
                float ph = k * s - wt + phase;
                float sn = sin(ph);
                float peak = saturate(sn);
                // A smooth sine plus a soft bulge on the crest, so the lip rounds instead of spiking.
                float h = amp * (sn + steep * 0.18 * peak * peak * peak);
                OceanSample o;
                o.h = h;
                o.crest = peak;
                return o;
            }

            static float oceanSurge(float x, float kick, float lt) {
                return kick * mix(0.014, 0.042, lt) * (0.78 + 0.22 * cos((x - 0.42) * 3.4));
            }

            fragment float4 oceanWavesFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = u.fx.x;
                float motion = mix(1.0, 0.4, calm);
                float clock = (u.resTime.z * 0.16 + u.misc.z * 0.11) * motion;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.40);
                float highs = bandAt(spectrum, 0.80);
                float drop = saturate(u.misc.y);
                float kick = u.env.x * (1.0 - calm);

                float2 uv = in.uv;
                float3 deep = u.c0.rgb;
                float3 face = u.c1.rgb;
                float3 foam = u.c2.rgb;
                float3 warm = float3(1.0, 0.80, 0.48);

                float3 sky = mix(deep * 0.05, mix(deep, face, 0.18) * 0.38, smoothstep(0.0, 0.55, uv.y));
                float2 moon = float2(0.72, 0.16);
                float2 md = (uv - moon) * float2(max(aspect, 0.85), 1.0);
                float dMoon = length(md);
                sky += warm * exp(-dMoon * dMoon * 4.8) * 0.62;
                float disc = smoothstep(0.098, 0.078, dMoon);
                float shadeDisc = 1.0 - saturate(dMoon / 0.098);
                shadeDisc = 0.78 + 0.22 * shadeDisc;
                sky = mix(sky, float3(1.0, 0.93, 0.76) * shadeDisc, disc * 0.95);
                float3 col = saturate(sky);

                const int layers = 4;
                float moving = 0.9 + mids * 3.15;
                float breakAmt = saturate(0.08 + bass * 0.72 + drop * 0.4);
                float steep = saturate(0.22 + bass * 0.55 + drop * 0.4);
                for (int i = 0; i < layers; i++) {
                    float fi = float(i);
                    float lt = fi / float(layers - 1);
                    float gate = saturate(moving - fi);
                    float spd = (0.4 + mids * 1.2) * mix(0.36, 1.0, lt) * (0.18 + 0.82 * gate);
                    float wt = clock * spd * 4.6;
                    float amp = mix(0.03, 0.078, pow(lt, 0.85));
                    amp *= 0.62 + bass * 0.9 + drop * 0.38;
                    float k = mix(1.85, 0.95, lt) * 6.2831853;
                    float phase = fi * 1.7 + 0.35;
                    float cycle = fract(clock * (0.11 + mids * 0.08));
                    float cycle2 = fract(cycle + 0.5);
                    float fade1 = smoothstep(0.0, 0.2, cycle) * smoothstep(1.0, 0.72, cycle);
                    float fade2 = smoothstep(0.0, 0.2, cycle2) * smoothstep(1.0, 0.72, cycle2);
                    float inbound = exp(-pow((lt - cycle) * 2.8, 2.0)) * fade1;
                    inbound += exp(-pow((lt - cycle2) * 2.8, 2.0)) * fade2;

                    float e = 0.005;
                    OceanSample a0 = oceanSample(uv.x, wt, amp, k, steep, phase);
                    OceanSample a1 = oceanSample(uv.x + e, wt, amp, k, steep, phase);
                    float lift = inbound * amp * 0.55;
                    float h = a0.h + lift + oceanSurge(uv.x, kick, lt);
                    float hR = a1.h + lift + oceanSurge(uv.x + e, kick, lt);
                    if (i == layers - 1) {
                        float audio = waveAt(wave, uv.x) * 0.006 * (0.2 + bass);
                        h += audio;
                        hR += audio;
                    }
                    float slopeUp = (hR - h) / e;
                    float base = mix(0.42, 0.88, pow(lt, 0.9));
                    float surface = base - h;
                    float depth = uv.y - surface;
                    float cover = smoothstep(-0.016, 0.02, depth);

                    float ripN = sin(uv.x * 36.0 + wt * 1.4) * highs * 0.06;
                    float3 n = normalize(float3(-(slopeUp + ripN) * 1.35, 1.0, 0.85));
                    float3 light = normalize(float3(moon.x - uv.x, 0.5, 0.9));
                    float diff = saturate(dot(n, light));
                    float spec = pow(saturate(dot(reflect(-light, n), float3(0.0, 0.2, 1.0))), 12.0);
                    float crestGate = smoothstep(0.45, 0.92, a0.crest);
                    float span = mix(0.16, 0.26, lt);
                    float t = saturate(depth / span);
                    float shade = t * t * (3.0 - 2.0 * t);
                    float3 litFace = mix(face, foam, 0.12 * crestGate);
                    float3 body = mix(litFace, deep * 0.55, shade);
                    body = mix(deep * 0.42, body, mix(0.62, 1.0, lt));
                    body *= 0.68 + 0.32 * diff;
                    float org = oceanFbm(float2(uv.x * 1.4 + clock * 0.12, fi + depth));
                    body *= 0.92 + 0.16 * (org - 0.45);
                    float sheen = pow(diff, 3.0) * exp(-max(depth, 0.0) * 4.5);
                    body += mix(foam, float3(1.0), 0.35) * sheen * (0.12 + highs * 0.35);
                    body += mix(foam, float3(1.0), 0.6) * spec * exp(-max(depth, 0.0) * 3.5) * (0.15 + highs);
                    float column = exp(-pow((uv.x - moon.x) * 2.8, 2.0));
                    body += warm * column * (1.0 - shade) * diff * 0.18;
                    float2 gv = float2(uv.x * 150.0 + clock * 1.6, uv.y * 88.0);
                    float2 gid = floor(gv);
                    float2 gf = fract(gv) - 0.5;
                    float spark = hash21(gid + float2(fi, 1.0));
                    float glint = step(0.986, spark) * smoothstep(0.46, 0.08, length(gf));
                    glint *= smoothstep(0.12, 0.55, highs) * (1.0 - shade) * (0.4 + diff);
                    body += float3(1.0) * glint * 0.85;
                    float3 water = saturate(body);

                    float curl = crestGate * breakAmt * 0.014;
                    float dLip = abs(uv.y - (surface - curl));
                    float width = mix(16000.0, 3200.0, breakAmt);
                    float core = exp(-dLip * dLip * width);
                    float grain = oceanNoise(float2(uv.x * 7.5 + wt * 0.15, fi * 1.7));
                    float broken = smoothstep(0.28, 0.72, grain);
                    float foamAmt = core * crestGate * (0.2 + breakAmt * 0.95 * broken);
                    foamAmt = saturate(foamAmt + core * crestGate * kick * 0.4);
                    foamAmt = saturate(foamAmt + core * crestGate * drop * 0.35);
                    float3 foamCol = mix(foam, float3(1.0), 0.5);

                    col = mix(col, water, cover);
                    col = mix(col, foamCol, foamAmt * (0.55 + 0.45 * cover));
                }

                float2 q = uv - float2(0.5, 0.4);
                col *= 1.0 - dot(q, q) * 0.18;
                return float4(saturate(col), 1.0);
            }
            """#
    }
#endif
