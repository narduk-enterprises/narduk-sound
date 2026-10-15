#if canImport(Metal)
    /// An opt-in Halo trial: a breathing glass core inside a tilted spectrum crown. The original Halo is unchanged.
    /// Bass and kick own the core; mids lift the crown; highs and hats light sparse orbiting beads. The existing
    /// state owns every envelope and palette transition. No extra clock, smoothing, full-screen flash or allocation.
    enum HaloOrbitShader {
        static let source = #"""
            fragment float4 haloOrbitFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float travel = u.misc.z * intensity;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.4);
                float highs = bandAt(spectrum, 0.8);
                float kick = u.env.x * intensity;
                float snare = u.env.y * intensity;
                float hat = u.env.z * intensity;
                float drop = u.misc.y * intensity;
                float beat = pow(1.0 - fract(u.resTime.w), 3.0) * intensity;
                // Preserve the whole subject in a narrow card, with deliberate symmetry and generous dark space.
                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0 / min(aspect, 1.0);
                float r = length(p);
                float3 light = fxKeyLight();
                float3 bodyTint = mix(u.c0.rgb, u.c1.rgb, 0.25);
                float3 accent = u.c1.rgb;
                float3 col = float3(0.002, 0.004, 0.009);

                // Ambient: a faint counter-drifting field; never a competing brightness pulse.
                float2 drift = float2(sin(time * 0.07), cos(time * 0.09)) * 0.03;
                col += bodyTint * exp(-r * r * 2.2) * 0.035;
                col += mix(u.c2.rgb, float3(0.7), 0.25) * fxStars(p + drift, 14.0, 4.0, -time * 0.2) * 0.16;

                // Secondary: a tilted crown of 48 rounded spectrum ribs. A fixed axis gives the eye an anchor;
                // a slow, continuous orbit carries the crown instead of spinning the whole composition each bar.
                float tilt = 0.32 + 0.035 * sin(time * 0.18);
                float2 q = float2(cos(tilt) * p.x - sin(tilt) * p.y,
                                  sin(tilt) * p.x + cos(tilt) * p.y);
                q.y /= 0.52;
                float qr = length(q) + 1e-4;
                float qa = atan2(q.y, q.x);
                float turn = fract(qa / 6.2831853 - travel * 0.008);
                float bandPosition = turn * 48.0;
                float tier = (floor(bandPosition) + 0.5) / 48.0;
                float value = pow(bandAt(spectrum, tier), 0.8);
                float crownR = 0.61 + 0.022 * mids + 0.018 * drop;
                float ribLength = 0.028 + 0.21 * value;
                float lateral = (fract(bandPosition) - 0.5) * 6.2831853 / 48.0 * qr;
                float along = clamp(qr - crownR, 0.0, ribLength);
                float distance = length(float2(lateral, qr - crownR - along));
                float2 beam = fxBeam(distance, 0.008);
                float front = smoothstep(-0.1, 0.25, q.y);
                float weight = (0.3 + 0.65 * front) * (0.5 + 0.8 * value);
                col += (bodyTint * beam.y * 1.05 + mix(bodyTint, float3(1.0), 0.58) * beam.x * 1.45) * weight;
                float2 crownBeam = fxBeam(abs(qr - crownR), 0.004);
                col += (accent * crownBeam.y * 0.24 + accent * crownBeam.x * 0.48) * (0.4 + 0.6 * front);

                // Supporting response: the snare's existing exponential envelope sends one eased arc outward.
                // This stays local to the subject; there are no extra full-frame flashes.
                float arcR = crownR + 0.32 * (1.0 - snare) * (1.0 - snare);
                float arc = exp(-pow((qr - arcR) * 85.0, 2.0)) * snare;
                col += accent * arc * pow(max(0.0, sin(qa)), 2.0) * 0.28;

                // Six small beads travel on the foreground orbit. Their brightness, rather than global density,
                // follows highs and hats, so the core stays the hero even in a dense drop.
                for (int bead = 0; bead < 6; bead++) {
                    float angle = float(bead) * 1.0471976 + travel * 0.075;
                    float2 center = float2(cos(angle), sin(angle)) * (crownR + 0.11);
                    float2 delta = q - center;
                    float beadR = 0.021 + 0.005 * highs;
                    float3 tint = mix(u.c2.rgb, float3(1.0), 0.45);
                    float depth = 0.24 + 0.55 * (0.5 + 0.5 * sin(angle));
                    col += fxBall(delta / beadR, light, tint) * depth * (0.3 + 0.45 * highs + 0.2 * hat);
                }

                // Primary: glossy plasma with a restrained breathing radius. Existing attack/release envelopes
                // give the immediate kick then the gentle settle. The waveform is a fine rim, not another hero.
                float coreR = 0.30 + 0.065 * bass + 0.033 * kick + 0.007 * beat;
                float2 rel = p / coreR;
                float d2 = dot(rel, rel);
                if (d2 < 1.1) {
                    float z = sqrt(max(1.0 - d2, 0.0));
                    float3 normal = float3(rel, z);
                    float2 lit = fxLight(normal, light, 24.0);
                    float plasma = fxFbm3(float3(rel * 2.6 + float2(time * 0.06, -time * 0.04), time * 0.1), 3);
                    float3 tint = mix(bodyTint, accent, smoothstep(0.35, 0.75, plasma));
                    float3 skin = tint * (0.16 + 1.05 * lit.x) * (0.65 + plasma * plasma);
                    skin += float3(1.0) * lit.y * 0.7;
                    skin += accent * pow(1.0 - z, 3.0) * 0.38;
                    skin += mix(accent, float3(1.0), 0.4) * z * (0.14 * bass + 0.1 * kick);
                    col = mix(col, skin, smoothstep(1.02, 0.96, sqrt(d2)));
                }
                float a = atan2(p.y, p.x);
                float w = wave[int(fract(a / 6.2831853) * 511.0)];
                float rimR = coreR * (1.025 + 0.022 * w);
                float2 rimBeam = fxBeam(abs(r - rimR), 0.0035);
                col += accent * (rimBeam.x * 0.42 + rimBeam.y * 0.14);
                col += accent * exp(-max(r - coreR, 0.0) * 18.0) * (0.035 + 0.035 * bass);
                // Front arc crosses the lower hemisphere after the core has occluded the rear half.
                float foreground = smoothstep(0.04, 0.18, q.y);
                float2 frontBeam = fxBeam(abs(qr - crownR), 0.005);
                col += (mix(accent, float3(1.0), 0.4) * frontBeam.x * 0.7
                        + accent * frontBeam.y * 0.22) * foreground;
                col = fxTonemap(col, 1.25);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
