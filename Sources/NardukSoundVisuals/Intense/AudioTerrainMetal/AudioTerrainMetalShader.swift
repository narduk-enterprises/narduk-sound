#if canImport(Metal)
    /// Audio terrain (Metal): a neon landscape rolling toward the viewer under a banded low sun. Fourteen ridges stand
    /// in perspective, drawn far to near so each hides what is behind it: the nearest six are the live waveform history
    /// (the newest nearest), the rest a noise landscape fixed to the ground that scrolls with the travel. Bass
    /// raises a wide central peak, the mids the shoulders and the highs a fine jitter at the edges; the kick and the
    /// beat lift the nearest ridge and fatten its glow. Each ridge is a dark body lit on its sun-facing slopes under a
    /// neon crest whose color fades with distance; below them the ground grid rolls on the beat, above them the sun
    /// sits in a glowing sky. A drop speeds the roll and warms the colors. No full-screen flash. The Metal port of the
    /// Canvas `audioTerrain`.
    enum AudioTerrainMetalShader {
        static let source = #"""
            constant constexpr float audioTerrainMetalNear = 1.18;
            constant constexpr float audioTerrainMetalFar = 10.5;
            constant constexpr float audioTerrainMetalCamera = 1.02;
            constant constexpr float audioTerrainMetalHalfWidth = 0.9;
            constant constexpr int audioTerrainMetalRows = 14;
            constant constexpr float audioTerrainMetalHorizon = 0.4;
            constant constexpr float audioTerrainMetalFocalX = 0.55;
            constant constexpr float audioTerrainMetalFocalY = 0.62;

            // The depth of row `index` (0 nearest) of `count` for a scroll phase in 0 ... 1.
            static float audioTerrainMetalDepth(float index, float count, float phase) {
                float v = (index + (1.0 - phase)) / count;
                return 1.0 / ((1.0 - v) / audioTerrainMetalNear + v / audioTerrainMetalFar);
            }

            static float audioTerrainMetalShape(float uu, float bass, float mids, float highs, float wave, float jitter, float lift) {
                float au = abs(uu);
                float center = exp(-uu * uu * 2.2);
                float shoulder = exp(-(au - 0.5) * (au - 0.5) * 16.0);
                float edge = max(0.0, (au - 0.62) / 0.38);
                float body = 0.04 + 0.40 * max(wave, 0.0);
                return 0.8 * (body + bass * center * 0.78 + mids * shoulder * 0.38 + highs * edge * (0.05 + 0.48 * abs(jitter)) + lift * (0.08 + 0.34 * center));
            }

            // The height of row `age` at column `column` (of 36): a live history sample for the nearest six rows.
            static float audioTerrainMetalColumn(
                constant float *history, int age, int column, float key, float bass, float mids, float highs, float lift, float energy) {
                float uu = float(column) / 35.0 * 2.0 - 1.0;
                float wave;
                if (age < 6) {
                    int i = clamp(int((uu * 0.5 + 0.5) * 127.0 + 0.5), 0, 127);
                    wave = history[age * 128 + i];
                } else {
                    wave = (fbm(float2(uu * 2.5 + 7.0, key * 0.31)) - 0.42) * (0.7 + 0.5 * energy);
                }
                float jitter = hash11(float(column) + key * 17.0) * 2.0 - 1.0;
                float h = audioTerrainMetalShape(uu, bass, mids, highs, wave, jitter, age == 0 ? lift : 0.0);
                float nearness = 1.0 - float(age) / float(audioTerrainMetalRows - 1);
                return h * (0.62 + 0.38 * nearness);
            }

            fragment float4 audioTerrainMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]], constant float *history [[buffer(5)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float travel = u.misc.z * intensity;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float drop = clamp(u.misc.y, 0.0, 1.0);
                float bass = bandAt(spectrum, 0.07);
                float mids = bandAt(spectrum, 0.4);
                float highs = bandAt(spectrum, 0.8);
                float beatPulse = pow(1.0 - fract(beats), 3.0) * intensity;
                float3 light = fxKeyLight();
                float px = u.resTime.y;

                float2 uv = in.uv + u.fx.zw * 0.004 * intensity;
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float scroll = travel * (1.0 + drop * 1.5);
                float phase = fract(scroll);
                float scrollBase = floor(scroll);
                float horizon = audioTerrainMetalHorizon;
                float3 gridTint = u.c0.rgb * (1.0 + 0.2 * drop);
                float3 ridgeTint = u.c1.rgb * (1.0 + 0.3 * drop);
                float3 sunTint = u.c2.rgb * (1.0 + 0.3 * drop);

                // Far: the sky, darkest at the top and glowing toward the horizon, with stars; and the banded sun.
                float skyT = clamp(uv.y / horizon, 0.0, 1.0);
                float aboveHorizon = step(uv.y, horizon);
                float3 col = float3(0.003, 0.004, 0.012) + (sunTint * (0.03 + 0.05 * energy) * pow(skyT, 2.2) + sunTint * (0.22 + 0.16 * drop + 0.08 * beatPulse + 0.4 * bass) * pow(skyT, 6.0) * 0.35) * aboveHorizon;
                col += mix(float3(0.7, 0.8, 1.0), u.c0.rgb, 0.4) * fxStars(float2(uv.x * aspect, uv.y), 26.0, 9.0, time) * (0.2 + 0.7 * highs) * (1.0 - skyT) * step(uv.y, horizon);
                {
                    float sunR = 0.145;
                    float2 sc = float2(0.5 * aspect, horizon - sunR * 0.12);
                    float2 sd = float2(uv.x * aspect, uv.y) - sc;
                    float dist = length(sd);
                    col += sunTint * exp(-max(dist - sunR, 0.0) * 6.0) * (0.12 + 0.12 * energy + 0.45 * bass + 0.1 * kick) * step(uv.y, horizon + 0.02);
                    if (dist < sunR) {
                        float along = (uv.y - (sc.y - sunR)) / (2.0 * sunR);
                        float band = floor(along * 8.0);
                        float included = along > 0.5 ? step(fmod(band, 2.0), 0.5) : 1.0;
                        float stripe = smoothstep(0.76, 0.66, abs(fract(along * 8.0) - 0.5) * 2.0);
                        float disc = smoothstep(sunR, sunR - 0.004, dist);
                        float3 sun = mix(sunTint, float3(1.0), 0.3 * (1.0 - along)) * (0.6 + 0.8 * (1.0 - along)) * (1.0 + 0.4 * kick + 0.7 * bass);
                        col = mix(col, sun, disc * included * stripe * 0.95);
                    }
                }

                // The ground: a grid whose rows roll toward the viewer on the beat, and spokes into the distance.
                if (uv.y > horizon) {
                    float z = audioTerrainMetalCamera * audioTerrainMetalFocalY / max(uv.y - horizon, 1e-4);
                    float inv = 1.0 / z;
                    float depthU = (inv - 1.0 / audioTerrainMetalNear) / (1.0 / audioTerrainMetalFar - 1.0 / audioTerrainMetalNear);
                    float ringCoord = depthU * 8.0 - (1.0 - phase);
                    float ringWidth = max(fwidth(ringCoord), 1e-4);
                    float ring = smoothstep(ringWidth * 1.6, 0.0, abs(fract(ringCoord + 0.5) - 0.5)) * step(0.0, depthU) * step(depthU, 1.0);
                    float x = (uv.x - 0.5) * z / audioTerrainMetalFocalX;
                    float spokeCoord = (x + audioTerrainMetalHalfWidth) / (2.0 * audioTerrainMetalHalfWidth) * 12.0;
                    float spokeWidth = max(fwidth(spokeCoord), 1e-4);
                    float spoke = smoothstep(spokeWidth * 1.6, 0.0, abs(fract(spokeCoord + 0.5) - 0.5)) * step(0.0, spokeCoord) * step(spokeCoord, 12.0);
                    float away = clamp(depthU, 0.0, 1.0);
                    float onGround = smoothstep(0.0, 0.01, uv.y - horizon) * step(abs(x), audioTerrainMetalHalfWidth * 1.04);
                    float lit = (0.28 + 0.16 * beatPulse + 0.1 * drop);
                    col += gridTint * (ring * (1.6 + 0.5 * beatPulse) * (1.0 - 0.6 * away) + spoke * lit * 2.0 * (1.0 - 0.5 * away)) * onGround * (0.8 + 0.6 * kick);
                    col += gridTint * (0.015 + 0.08 * exp(-(uv.y - horizon) * 9.0)) * onGround * (1.0 - away);
                }
                col += sunTint * exp(-abs(uv.y - horizon) * 40.0) * (0.12 + 0.1 * drop + 0.1 * beatPulse);

                // The ridges, far to near: a dark body lit on the slopes facing the sun, and a neon crest.
                float lift = kick * 0.7 + beatPulse * 0.45;
                for (int age = audioTerrainMetalRows - 1; age >= 0; age--) {
                    float z = audioTerrainMetalDepth(float(age), float(audioTerrainMetalRows), phase);
                    float xw = (uv.x - 0.5) * z / audioTerrainMetalFocalX;
                    float uu = xw / audioTerrainMetalHalfWidth;
                    if (abs(uu) > 1.0) continue;
                    float key = float(age) + scrollBase;
                    float cf = (uu * 0.5 + 0.5) * 35.0;
                    int c0 = int(clamp(floor(cf), 0.0, 34.0));
                    float h0 = audioTerrainMetalColumn(history, age, c0, key, bass, mids, highs, lift, energy);
                    float h1 = audioTerrainMetalColumn(history, age, c0 + 1, key, bass, mids, highs, lift, energy);
                    float h = mix(h0, h1, cf - float(c0));
                    float yScreen = horizon + (audioTerrainMetalCamera - h) / z * audioTerrainMetalFocalY;
                    float x0 = 0.5 + ((float(c0) / 35.0 * 2.0 - 1.0) * audioTerrainMetalHalfWidth) / z * audioTerrainMetalFocalX;
                    float x1 = 0.5 + ((float(c0 + 1) / 35.0 * 2.0 - 1.0) * audioTerrainMetalHalfWidth) / z * audioTerrainMetalFocalX;
                    float y0 = horizon + (audioTerrainMetalCamera - h0) / z * audioTerrainMetalFocalY;
                    float y1 = horizon + (audioTerrainMetalCamera - h1) / z * audioTerrainMetalFocalY;
                    float slope = (y1 - y0) / max((x1 - x0) * aspect, 1e-5);
                    float away = float(age) / float(audioTerrainMetalRows - 1);
                    float nearness = 1.0 - away;
                    // The body: dark, with the slopes that face left (the sun's side) catching its light.
                    if (uv.y > yScreen) {
                        float depthFog = exp(-(uv.y - yScreen) * 7.0);
                        float facing = clamp(0.5 - slope * 0.35, 0.0, 1.0);
                        float3 body = float3(0.002, 0.003, 0.008) + ridgeTint * (0.01 + 0.07 * facing * depthFog) * (0.4 + 0.6 * nearness) + sunTint * 0.02 * depthFog * (0.5 + 0.5 * energy);
                        col = mix(col, body, 0.1 + 0.8 * depthFog);
                    }
                    // The crest: a hot core and a glow, brighter and thicker toward the viewer.
                    float d = abs(uv.y - yScreen) / sqrt(1.0 + slope * slope);
                    float w = (0.0022 + 0.0018 * nearness) * (age == 0 ? 1.0 + 0.5 * kick + 0.25 * beatPulse : 1.0);
                    float2 beam = fxBeam(d, w);
                    beam.y /= 1.0 + 0.4 * min(abs(slope), 8.0);
                    float alpha = age == 0 ? 1.0 : (age < 3 ? 0.62 + 0.12 * drop : 0.36 + 0.1 * drop);
                    float fade = alpha * (0.35 + 0.65 * nearness);
                    float3 hot = mix(ridgeTint, float3(1.0), age == 0 ? 0.35 + 0.2 * kick : 0.15);
                    col += (hot * beam.x * 1.3 + ridgeTint * beam.y * (age == 0 ? 1.1 + 0.9 * kick : 0.5)) * fade * step(abs(uu), 1.0);
                }

                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.12);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
