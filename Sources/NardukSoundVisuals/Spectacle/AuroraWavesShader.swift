#if canImport(Metal)
    /// Aurora waves: broad silky ribbons that flow left to right as S-waves across a violet night sky, with a thin
    /// spectrum of light rising out of them, an aurora haze above and a calm sea below that reflects it all.
    ///
    /// The ribbons are the music: each one rides a smoothed trace of the live waveform and a ridge of the live
    /// spectrum over a slow S-curve, so they jump with every frame of sound. A kick punches them outward and thickens
    /// them (fast attack, 0.16 s decay); a snare sends a shockwave out along them from the centre; hats make the silk
    /// sparkle; the aurora rays above leap with the spectrum. Bass swells amplitude and thickness, mids fold the
    /// strands, the spectrum raises the embedded equaliser bars, the highs twinkle the stars. Glow stays bounded,
    /// never a full-frame flash; `dropAmount` brightens and saturates. `fx.x` is the calm flag: motion drops to 0.4,
    /// the audio displacement softens and the drum reactions go away.
    /// Colors come from c0/c1/c2 and tints of them: c1 the pink ribbon and horizon, c1+c2 the lavender ribbon and the
    /// sky, c2 the cyan ribbon, c0+c2 the mint ribbon and the aurora haze.
    enum AuroraWavesShader {
        static let source = #"""

            static float awNoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                float a = hash21(i);
                float b = hash21(i + float2(1.0, 0.0));
                float c = hash21(i + float2(0.0, 1.0));
                float d = hash21(i + float2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }

            struct AuroraWavesScene {
                float aspect;
                float waveScale;  // x stretch for the waves, so a portrait card still shows an S-curve
                float starCells;  // star grid cells per unit, fewer on a small drawable
                float pixel;      // one pixel in uv-y units
                float phase;      // the waves' shared phase
                float flow;       // the flow clock: time plus musical travel, drives the morphing and the silk
                float bass;
                float mids;
                float highs;
                float twinkle;    // star twinkle clock
                float kick;       // drum envelopes, zero in calm
                float snare;
                float hat;
                float live;       // how much the live audio displaces the ribbons (1, softer in calm)
                float centre;     // where the snare shockwave starts, in wave units
                float coreGlow;   // 1 + the bounded beat swell
                float light;      // overall brightness (drop)
                float sharp;      // 1 in the sky, 0 in the reflection (softer strands, no bars or stars)
                float3 pink;
                float3 lavender;
                float3 cyan;
                float3 mint;
            };

            // The centre line and half-width of ribbon `i` at wx (wave units) and xn (0 ... 1 across), in uv-y units
            // (up from the bottom). A slow S-curve that keeps changing shape, plus the live sound: a smoothed
            // waveform trace, a spectrum ridge, the kick's punch and the snare's travelling shockwave.
            static float2 awRibbon(
                thread const AuroraWavesScene &s, int i, float x, float xn, constant float *spectrum,
                constant float *wave
            ) {
                float fi = float(i);
                float f = s.flow;
                float k = 2.4 + 0.5 * fi + 0.45 * sin(f * 0.11 + fi * 1.7);
                float base = 0.52 + 0.06 * sin(fi * 2.4 + 0.5) + 0.03 * sin(f * 0.21 + fi * 1.9);
                float amp = (0.06 + 0.04 * s.bass) * (1.0 - 0.06 * fi);
                float travelling = sin(k * x - s.phase * (1.0 + 0.2 * fi) + fi * 2.2);
                float counter = sin(0.55 * k * x + f * (0.45 + 0.1 * fi) + fi * 4.1);
                float warp = awNoise(float2(x * 1.25 - f * (0.3 + 0.06 * fi), fi * 7.3 + f * 0.09)) - 0.5;
                float center = base + amp * (0.7 * travelling + 0.4 * counter) + 0.08 * warp;

                float punch = 1.0 + 1.6 * s.kick;
                // A window of the waveform that never wraps (the buffer's ends do not meet), smoothed and softly
                // limited so a loud pure tone bends the ribbon instead of turning it into a sine wave.
                float trace = 0.08 + clamp(xn, 0.0, 1.0) * 0.55 + fi * 0.07;
                float osc = 0.0;
                for (int j = -2; j <= 2; j++) { osc += waveAt(wave, trace + float(j) * 0.01); }
                osc *= 0.2;
                osc /= 1.0 + 1.5 * abs(osc);
                center += osc * (0.07 + 0.05 * s.bass) * punch * s.live;
                float bandT = 0.04 + 0.9 * abs(fract(xn * 0.8 + fi * 0.23) * 2.0 - 1.0);
                float ridge = bandAt(spectrum, bandT);
                center += (ridge - 0.2) * 0.07 * punch * s.live * (i % 2 == 0 ? 1.0 : -0.7);

                float front = abs(x - s.centre) - (1.0 - s.snare) * 1.1;
                center += s.snare * 0.07 * exp(-front * front / 0.012) * (i % 2 == 0 ? 1.0 : -1.0);

                float swell = 0.62 + 0.38 * sin(x * (1.5 + 0.3 * fi) - f * (0.8 + 0.15 * fi) + fi * 2.1);
                float halfWidth = (0.062 + 0.055 * s.bass + 0.015 * s.kick) * swell * (1.08 - 0.07 * fi);
                return float2(center, halfWidth);
            }

            // Everything above the horizon at q = (x in aspect units, y up from the bottom, 0 ... 1). The sea calls
            // it too, at the mirrored point, so each pixel evaluates the sky once.
            static float3 awSky(
                thread const AuroraWavesScene &sc, float2 q, constant float *spectrum, constant float *wave
            ) {
                float x = q.x;
                float wx = x * sc.waveScale;
                float xn = x / max(sc.aspect, 0.1);
                float y = q.y;
                float horizon = 0.16;
                float above = max(y - horizon, 0.0);

                // Sky: deep indigo overhead to violet at the horizon, and a pink horizon glow.
                float3 skyTop = sc.lavender * sc.lavender * 0.12 + float3(0.004, 0.005, 0.02);
                float3 skyMid = sc.lavender * sc.lavender * 0.4;
                float3 skyLow = mix(sc.lavender, sc.pink, 0.3) * 0.38;
                float3 color = mix(skyLow, skyMid, smoothstep(0.0, 0.3, above));
                color = mix(color, skyTop, smoothstep(0.25, 0.8, above));
                color += mix(sc.pink, float3(1.0), 0.2) * exp(-above / 0.04) * 0.38;
                color += mix(sc.pink, sc.lavender, 0.5) * exp(-above / 0.14) * 0.12;
                // Thin dark cloud streaks just above the horizon.
                float cloud = awNoise(float2(x * 2.2, y * 70.0)) * awNoise(float2(x * 6.0 + 3.0, y * 22.0));
                float cloudBand = smoothstep(0.165, 0.185, y) * smoothstep(0.3, 0.2, y);
                color *= 1.0 - smoothstep(0.22, 0.5, cloud) * cloudBand * 0.3 * sc.sharp;

                // Stars: fine points that twinkle with the highs, and a few soft pink motes.
                float2 gv = (float2(x, y) + float2(sc.flow * 0.006, 0.0)) * sc.starCells;
                float2 id = floor(gv);
                float h = hash21(id);
                float2 jitter = float2(hash21(id + 7.1), hash21(id + 3.3)) - 0.5;
                float starSize = sc.pixel * sc.starCells * 1.1;
                float star = smoothstep(starSize, 0.0, length(fract(gv) - 0.5 - jitter * 0.6)) * step(0.86, h);
                float tw = 0.45 + 0.55 * sin(sc.twinkle * (1.0 + 3.0 * h) + h * 41.0);
                tw = mix(0.75, tw, 0.35 + 0.65 * saturate(sc.highs * 2.0));
                float starLight = (0.35 + 0.65 * h + 0.6 * sc.highs) * sc.sharp;
                color += mix(float3(1.0), sc.lavender, 0.3) * star * tw * starLight * smoothstep(0.02, 0.12, above);
                float2 mv = float2(x, y) * 13.0 + float2(sc.flow * 0.08, -sc.flow * 0.12);
                float2 mid = floor(mv);
                float mh = hash21(mid + 11.0);
                float2 mj = float2(hash21(mid + 5.2), hash21(mid + 9.4)) - 0.5;
                float mote = smoothstep(0.08, 0.0, length(fract(mv) - 0.5 - mj * 0.5)) * step(0.84, mh);
                color += mix(sc.pink, float3(1.0), 0.4) * mote * (0.25 + 0.3 * sc.highs) * smoothstep(0.03, 0.15, above);

                // Aurora haze: a broad green-cyan sweep above the ribbons, a soft lower hem fading upward in streaks.
                float hem = 0.655 + 0.1 * sin(wx * 1.5 - sc.flow * 0.4 + 1.2) + 0.035 * sin(wx * 4.1 + sc.flow * 0.55);
                float streaks = awNoise(float2(wx * 9.0 + y * 5.0 - sc.flow * 0.9, y * 2.0 + sc.flow * 0.2));
                float folds = awNoise(float2(wx * 1.8 - sc.flow * 0.22, 1.7 + sc.flow * 0.07));
                float rays = bandAt(spectrum, 0.04 + 0.9 * abs(fract(xn * 0.7 + 0.1 + 0.05 * folds) * 2.0 - 1.0));
                hem -= 0.05 * rays * sc.live;
                float rise = y - hem;
                float curtain = rise < 0.0 ? exp(-pow(rise / 0.06, 2.0)) : exp(-rise / (0.08 + 0.06 * folds + 0.1 * rays * sc.live));
                curtain *= (0.5 + 0.5 * streaks) * (0.3 + 0.7 * smoothstep(0.15, 0.75, folds)) * (0.75 + 0.9 * rays * sc.live);
                float3 hazeColor = mix(sc.mint, sc.cyan, smoothstep(0.3, 1.1, x / max(sc.aspect, 0.5) + 0.3 * folds));
                color += hazeColor * curtain * 2.1 * sc.light;

                // Ribbons: many fine parallel strands with a luminous core and a soft bloom.
                float strandsPerHalf = clamp(0.06 / max(sc.pixel * 4.5, 1e-4), 2.5, 9.0);
                float fold = 0.35 + 1.2 * sc.mids;
                for (int i = 0; i < 4; i++) {
                    float2 r = awRibbon(sc, i, wx, xn, spectrum, wave);
                    float d = y - r.x;
                    float v = d / max(r.y, 1e-4);
                    float av = abs(v);
                    if (av > 7.0) { continue; }
                    float fi = float(i);
                    float3 hue = i == 0 ? sc.pink : (i == 1 ? sc.lavender : (i == 2 ? sc.cyan : sc.mint));
                    float3 next = i == 0 ? sc.lavender : (i == 1 ? sc.cyan : (i == 2 ? sc.mint : sc.cyan));
                    float folded = v + fold * 0.35 * sin(wx * 4.5 + v * 1.5 - sc.flow * 1.6 + fi * 1.7);
                    float strandIndex = floor(folded * strandsPerHalf + 0.5);
                    float strand = pow(0.5 + 0.5 * cos(folded * strandsPerHalf * 6.28318), 2.0);
                    // Silk: light streams along each strand, every strand at its own speed.
                    float speed = 1.6 + 1.4 * hash21(float2(strandIndex, fi * 5.7));
                    float silk = awNoise(float2(wx * 7.0 - sc.flow * speed, strandIndex * 1.73 + fi * 9.1));
                    strand *= (0.25 + 0.75 * smoothstep(0.2, 0.85, silk)) * (1.0 + 0.9 * sc.hat * smoothstep(0.6, 0.9, silk));
                    strand = mix(0.45, strand, sc.sharp);
                    float body = smoothstep(1.1, 0.25, av);
                    float along = 0.5 + 0.5 * sin(wx * (1.6 + 0.3 * fi) + fi * 2.7 - sc.flow * (1.1 + 0.2 * fi));
                    float core = exp(-v * v * 3.5);
                    float bloom = exp(-av * 0.7);
                    float3 tint = mix(hue, next, 0.3 * saturate(0.5 + 0.5 * v));
                    float3 ribbon = tint * body * (0.3 + 0.6 * strand) * (0.4 + 0.6 * along);
                    ribbon += mix(tint, float3(1.0), 0.4) * core * 0.3 * (0.3 + 0.7 * along) * sc.coreGlow;
                    ribbon += hue * bloom * 0.2 * (0.5 + 0.5 * along);
                    color += ribbon * sc.light;
                }

                // Equaliser: thin vertical bars riding the central ribbon, one real spectrum band each.
                float barSpacing = max(sc.pixel * 13.0, 0.012);
                float column = floor(x / barSpacing);
                float local = (x / barSpacing - column - 0.5) * barSpacing;
                float bandT = mix(0.12, 1.0, fract(column * 0.6180339 + 0.31));
                float level = saturate(bandAt(spectrum, bandT) * (1.0 + 1.8 * bandT)) * (0.3 + 0.7 * hash21(float2(column, 4.7)));
                float barHeight = (0.008 + 0.075 * level) * (0.85 + 0.3 * saturate(sc.highs * 2.5));
                float2 spine = awRibbon(sc, 1, wx, xn, spectrum, wave);
                float riseBar = y - spine.x;
                float extent = riseBar > 0.0 ? barHeight : barHeight * 0.3;
                float alongBar = saturate(abs(riseBar) / max(extent, 1e-4));
                float barWidth = sc.pixel * 0.8;
                float bar = smoothstep(barWidth * 1.6, barWidth * 0.3, abs(local)) * (1.0 - alongBar * alongBar)
                    * step(abs(riseBar), extent) * sc.sharp;
                float3 barHue = mix(sc.lavender, sc.mint, smoothstep(0.3, 0.9, x / max(sc.aspect, 0.5)));
                color += mix(barHue, float3(1.0), 0.45) * bar * 0.5 * sc.light;
                return color;
            }

            fragment float4 auroraWavesFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = saturate(u.fx.x);
                float motion = mix(1.0, 0.4, calm);
                float t = u.resTime.z;
                float drop = saturate(u.misc.y);

                AuroraWavesScene sc;
                sc.aspect = aspect;
                sc.waveScale = max(1.0, 0.9 / max(aspect, 0.1));
                sc.pixel = 1.0 / max(u.resTime.y, 1.0);
                sc.sharp = 1.0;
                sc.starCells = clamp(0.085 * max(u.resTime.y, 1.0), 22.0, 64.0);
                sc.bass = (bandAt(spectrum, 0.02) + bandAt(spectrum, 0.07) + bandAt(spectrum, 0.13)) / 3.0;
                sc.mids = (bandAt(spectrum, 0.25) + bandAt(spectrum, 0.4) + bandAt(spectrum, 0.52)) / 3.0;
                sc.highs = (bandAt(spectrum, 0.65) + bandAt(spectrum, 0.8) + bandAt(spectrum, 0.95)) / 3.0;
                sc.flow = (t * 0.5 + u.misc.z * 0.1) * motion + sc.mids * 0.6;
                sc.phase = (t * 0.6 + u.misc.z * 0.12) * motion + sc.mids * 1.1;
                sc.twinkle = t * 2.2 * motion;
                float drums = 1.0 - calm;
                sc.kick = saturate(u.env.x) * drums;
                sc.snare = saturate(u.env.y) * drums;
                sc.hat = saturate(u.env.z) * drums;
                sc.live = mix(1.0, 0.4, calm);
                sc.centre = 0.5 * aspect * sc.waveScale;
                float beatPulse = pow(1.0 - fract(u.resTime.w), 3.0);
                sc.coreGlow = 1.0 + (1.0 - calm) * (0.5 * saturate(u.env.x) + 0.25 * beatPulse);
                sc.light = 0.85 + 0.3 * drop + 0.15 * u.wobble.z;
                float3 white = float3(0.86, 0.82, 1.0);
                sc.pink = mix(u.c1.rgb, white, 0.22);
                sc.lavender = mix(mix(u.c1.rgb, u.c2.rgb, 0.5), white, 0.22);
                sc.cyan = mix(u.c2.rgb, white, 0.12);
                sc.mint = mix(mix(u.c0.rgb, u.c2.rgb, 0.4), white, 0.06);

                float x = in.uv.x * aspect;
                float y = 1.0 - in.uv.y;
                float horizon = 0.16;
                float3 color;
                if (y >= horizon) {
                    color = awSky(sc, float2(x, y), spectrum, wave);
                } else {
                    // Sea: the sky mirrored about the horizon (compressed, so the ribbons reach the water), broken
                    // by perspective ripples, darkened with depth, with pink shimmer near the horizon.
                    float depth = (horizon - y) / horizon;
                    float rz = 0.05 / (horizon - y + 0.01);
                    float swellT = t * 0.5 * motion;
                    float ripple = awNoise(float2(x * 5.0 / (0.3 + 0.7 * depth), rz * 5.0 + swellT)) - 0.5;
                    float fine = awNoise(float2(x * 22.0, rz * 18.0 - swellT * 1.7)) - 0.5;
                    float2 mirrored = float2(
                        x + (ripple * 0.035 + fine * 0.012) * (0.4 + depth), horizon + (horizon - y) * 2.6
                            + (ripple * 0.06 + fine * 0.02) * (0.3 + depth));
                    sc.sharp = 0.0;
                    float3 sky = awSky(sc, mirrored, spectrum, wave);
                    float3 deep = sc.lavender * sc.lavender * 0.1 + float3(0.004, 0.004, 0.014);
                    color = deep + sky * (0.58 - 0.3 * depth);
                    float glint = pow(saturate(awNoise(float2(x * 34.0, rz * 26.0 + swellT * 2.0))), 7.0);
                    color += mix(sc.pink, float3(1.0), 0.3) * glint * exp(-depth * 3.5) * 0.9;
                }

                // Drop: brighter and more saturated. Then a soft tone map so additive layers never clip to white.
                float luma = dot(color, float3(0.299, 0.587, 0.114));
                color = max(mix(float3(luma), color, 1.0 + 0.3 * drop), 0.0);
                color = 1.0 - exp(-color * 1.25);
                return float4(color, 1.0);
            }
            """#
    }
#endif
