#if canImport(Metal)
    /// Scope (Metal): the waveform as a phosphor beam on curved CRT glass, triggered on a rising zero crossing so the
    /// trace holds still. Behind the main beam five older traces recede up the glass, each dimmer and tinted toward
    /// the palette's far colour; behind them a lit graticule whose lines glow where the beam passes; in front, scanlines,
    /// a glare streak and a dark rounded bezel. Bass swells the phosphor bloom and the glass behind the trace; highs
    /// sparkle along the beam and brighten the graticule's edges; a kick flares the beam and the glass; a snare sweeps a
    /// sync bar across the screen; the beat pulses the center axes. Calm shortens nothing, it only slows the drift.
    /// The Metal port of the Canvas `scope`.
    enum ScopeMetalShader {
        static let source = #"""
            // The live waveform at fractional sample `k` (linear), or the idle sine while the source is silent.
            static float scopeMetalAmp(constant float *wave, float k, float time, float silent) {
                float i0 = clamp(floor(k), 0.0, 510.0);
                float f = clamp(k - i0, 0.0, 1.0);
                float live = mix(wave[int(i0)], wave[int(i0) + 1], f);
                float idle = 0.06 * sin(time * 2.5 + k * 0.07);
                return clamp(mix(live, idle, silent), -1.0, 1.0);
            }

            // An older trace, `age` frames back, at x in 0 ... 1 (linear between its 128 points).
            static float scopeMetalHistory(constant float *aux, int age, float x) {
                float k = clamp(x, 0.0, 1.0) * 127.0;
                int i = int(min(floor(k), 126.0));
                return mix(aux[age * 128 + i], aux[age * 128 + i + 1], k - float(i));
            }

            fragment float4 scopeMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]], constant float *history [[buffer(5)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);
                float beatPulse = pow(1.0 - fract(beats), 3.0);
                float silent = aux[119];
                float trigger = aux[118];
                float px = u.resTime.y;

                // The glass: a mild barrel bulge and a rounded screen with a dark bezel around it.
                float2 q = in.uv - 0.5;
                float2 wu = 0.5 + q * (1.0 + 0.11 * dot(q, q) * 2.0);
                float2 sp = (wu - 0.5) * float2(aspect, 1.0);
                float sdf = fxRoundBox(sp, float2(0.5 * aspect - 0.025, 0.465), 0.075);
                float screen = smoothstep(0.003, -0.003, sdf);
                float vig = clamp(1.0 - 0.9 * dot(q, q) * 1.6, 0.0, 1.0);

                // Far: the glass itself, a deep green-blue glow that breathes with the bass and the kick, and static.
                float3 deep = mix(u.c0.rgb, u.c1.rgb, 0.5);
                float3 col = float3(0.002, 0.005, 0.008) + deep * (0.07 + 0.1 * energy + 0.2 * bass + 0.1 * kick) * exp(-dot(q, q) * 3.2);
                float staticNoise = hash21(floor(in.uv * float2(u.resTime.x, u.resTime.y) * 0.5) + floor(time * 30.0));
                col += float3(0.6, 0.8, 1.0) * staticNoise * staticNoise * staticNoise * (0.01 + 0.05 * highs + 0.03 * hat);

                float ux = (wu.x - 0.04) / 0.92;
                float2 ps = float2(wu.x * aspect, wu.y);
                float onScreen = step(0.0, ux) * step(ux, 1.0);

                // The main trace, as segments through the samples around this pixel: a hot core and a soft halo, brighter
                // where the beam travels slowly (a steep stroke is dimmer, as on a real scope).
                float2 beam = float2(0.0);
                float beamY = 0.5;
                {
                    float k = trigger + clamp(ux, 0.0, 1.0) * 383.0;
                    float k0 = floor(k) - 2.0;
                    float best = 1e3;
                    float slow = 1.0;
                    for (int j = 0; j < 5; j++) {
                        float ka = k0 + float(j);
                        float kb = ka + 1.0;
                        float2 a = float2((0.04 + 0.92 * (ka - trigger) / 383.0) * aspect, 0.5 - scopeMetalAmp(wave, ka, time, silent) * 0.4);
                        float2 b = float2((0.04 + 0.92 * (kb - trigger) / 383.0) * aspect, 0.5 - scopeMetalAmp(wave, kb, time, silent) * 0.4);
                        float d = fxSegment(ps, a, b);
                        if (d < best) {
                            best = d;
                            slow = 1.0 / sqrt(1.0 + 140.0 * (b.y - a.y) * (b.y - a.y) / max(1e-4, (b.x - a.x) * (b.x - a.x)) * 0.01);
                        }
                    }
                    beamY = 0.5 - scopeMetalAmp(wave, k, time, silent) * 0.4;
                    beam = fxBeam(best, 0.0032 + 0.0014 * bass + 0.0012 * kick) * slow;
                }

                // The graticule: eight columns, four rows and ticks along the center axes. The beam lights the glass
                // nearby, the beat pulses the axes and the highs brighten the outer edges.
                {
                    float gx = abs(fract(ux * 8.0 + 0.5) - 0.5) / 8.0 * 0.92 * aspect;
                    float gy = abs(fract((wu.y - 0.1) / 0.2 + 0.5) - 0.5) * 0.2;
                    float lines = exp(-pow(gx * px * 0.7, 2.0)) + exp(-pow(gy * px * 0.7, 2.0));
                    float axis = exp(-pow((wu.y - 0.5) * px * 0.7, 2.0)) + exp(-pow((ux - 0.5) * 0.92 * aspect * px * 0.7, 2.0));
                    float tickMark = exp(-pow(abs(fract(ux * 40.0 + 0.5) - 0.5) / 40.0 * 0.92 * aspect * px * 0.9, 2.0)) * smoothstep(0.014, 0.0, abs(wu.y - 0.5)) * 1.6;
                    float nearBeam = 1.0 + 4.0 * exp(-abs(wu.y - beamY) * 14.0) * (0.4 + 0.6 * energy);
                    float edge = 0.4 + 1.8 * highs * smoothstep(0.2, 0.5, abs(ux - 0.5));
                    float3 grid = mix(u.c0.rgb, u.c1.rgb, 0.7) * (lines * 0.16 + axis * (0.1 + 0.2 * beatPulse) + tickMark * 0.22);
                    col += grid * nearBeam * edge * onScreen * (0.8 + 0.6 * kick);
                }

                // Middle: older traces, each higher, shorter and dimmer, tinted from the beam's color toward the far one.
                for (int age = 1; age < 6; age++) {
                    float depth = float(age) / 5.0;
                    float scaleX = 1.0 - 0.09 * float(age);
                    float hx = (ux - 0.5) / scaleX + 0.5;
                    if (hx < 0.0 || hx > 1.0) continue;
                    float centerY = 0.5 - 0.075 * float(age) * (1.0 + 0.0 * drop);
                    float height = 0.4 * (1.0 - 0.13 * float(age));
                    float yv = centerY - scopeMetalHistory(history, age, hx) * height;
                    float yl = centerY - scopeMetalHistory(history, age, hx - 0.01) * height;
                    float yr = centerY - scopeMetalHistory(history, age, hx + 0.01) * height;
                    float slope = (yr - yl) / (0.02 * scaleX * 0.92 * aspect);
                    float d = abs(wu.y - yv) / sqrt(1.0 + slope * slope);
                    float2 line = fxBeam(d, 0.0026 * (1.0 - 0.3 * depth));
                    float3 tint = mix(u.c1.rgb, u.c0.rgb, depth);
                    float fade = 1.5 * pow(0.66, float(age)) * (hx > 0.0 ? 1.0 : 0.0);
                    float haveHistory = step(1e-4, abs(scopeMetalHistory(history, age, 0.5)) + abs(scopeMetalHistory(history, age, 0.1)));
                    col += tint * (line.x * 0.8 + line.y * 0.7) * fade * onScreen * mix(0.15, 1.0, haveHistory);
                }

                // Near: the beam and its bloom. The bass fattens the bloom, a kick flares it, the highs sparkle on it.
                float3 hot = mix(u.c1.rgb, float3(1.0), 0.55);
                float flare = 1.0 + 1.1 * kick + 0.5 * beatPulse * energy;
                col += (hot * beam.x * 2.2 + u.c1.rgb * beam.y * (1.3 + 2.4 * bass)) * flare * onScreen;
                float spark = hash21(floor(float2(ux * 480.0, time * 20.0))) ;
                col += u.c2.rgb * beam.x * step(0.82, spark) * (0.1 + 1.6 * highs * highs) * onScreen;
                col += u.c1.rgb * exp(-abs(wu.y - beamY) * 7.0) * 0.05 * (0.4 + 1.8 * bass) * onScreen;

                // A snare is a sync bar sweeping left to right as it decays.
                float bar = exp(-pow((ux - (1.0 - snare)) * 24.0, 2.0)) * smoothstep(0.02, 0.2, snare);
                col += mix(u.c2.rgb, float3(1.0), 0.4) * bar * (0.1 + 0.25 * snare) * smoothstep(0.55, 0.0, abs(wu.y - 0.5)) * onScreen;

                // Glass: scanlines, a glare streak across the upper left, the vignette.
                col *= 0.86 + 0.14 * sin(in.uv.y * px * 3.14159);
                float glare = exp(-pow((dot(wu - float2(0.18, 0.12), normalize(float2(0.7, 0.7))) ) * 9.0, 2.0)) * smoothstep(0.65, 0.1, wu.x + wu.y * 0.6);
                col += float3(0.8, 0.9, 1.0) * glare * 0.07;
                col *= vig;
                col *= screen;

                // The bezel: near-black with a thin lit lip around the glass.
                float lip = exp(-pow(sdf * px * 0.4, 2.0)) * 0.07 * (0.5 + 0.5 * energy);
                col += mix(float3(0.01, 0.012, 0.016), deep * 0.4, lip * 12.0) * (1.0 - screen) * (0.4 + 0.6 * exp(-max(sdf, 0.0) * 18.0));

                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.35);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
