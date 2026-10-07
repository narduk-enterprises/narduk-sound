#if canImport(Metal)
    /// Vortex (Metal): a spiral galaxy drawn from the spectrum. Three arms wind out of a hot core; position along an arm
    /// is the band (bass at the core, highs at the rim) and an arm swells where its band is loud. The arms are lit gas:
    /// a ridge-free density (an arm profile times 3-D fractal noise) turned into a finite-difference normal, so each
    /// arm has a bright side, a dark lane and a white specular edge, with a bead of shaded light on every band, tiered
    /// by range, and a white tick where its peak was. A differentially rotating starfield sits behind, the waveform
    /// wraps the core as an accretion ring, a snare throws a shock ring, a kick swells the core, every beat leaves a
    /// faint ring, a drop winds the arms tighter and a glitch splits them into two fringes. The Metal port of the
    /// Canvas `vortex`.
    enum VortexMetalShader {
        static let source = #"""
            // A band's radius as a fraction of the galaxy radius (the Canvas `vortexBandRadius`, amplitude folded in by the caller).
            static float vortexMetalRadius(float t) {
                return 0.09 + 0.86 * pow(t, 0.72);
            }

            // The band at a radius fraction: the inverse of `vortexMetalRadius`.
            static float vortexMetalBandAt(float rho) {
                return pow(clamp((rho - 0.09) / 0.86, 0.0, 1.0), 1.0 / 0.72);
            }

            // An arm's angle at band position `t`.
            static float vortexMetalAngle(float t, int arm, float rotation, float twist) {
                return float(arm) * 2.0943951 + rotation + twist * 6.2831853 * pow(t, 0.85);
            }

            static float vortexMetalWrap(float a) {
                return a - 6.2831853 * floor(a / 6.2831853 + 0.5);
            }

            // The gas density of all three arms at p: each an arm profile (wider and brighter where its band is loud)
            // broken up by 3-D fractal noise, fading out at the rim.
            static float vortexMetalGas(
                float2 p, float radius, float rotation, float twist, float time, constant float *spectrum) {
                float r = length(p) + 1e-4;
                float rho = r / radius;
                float t = vortexMetalBandAt(rho);
                float level = bandAt(spectrum, t);
                float a = atan2(p.y, p.x);
                float width = 0.05 + 0.11 * rho + 0.05 * level;
                float noise = 0.65 * fxFbm3(float3(p * 4.0, time * 0.1), 3) + 0.35 * fxNoise3(float3(p * 15.0, time * 0.2));
                float density = 0.0;
                for (int arm = 0; arm < 3; arm++) {
                    float d = vortexMetalWrap(a - vortexMetalAngle(t, arm, rotation, twist)) * r;
                    density += exp(-d * d / (width * width));
                }
                float rim = smoothstep(1.02, 0.8, rho) * smoothstep(0.03, 0.12, rho);
                return density * (0.2 + 1.5 * noise * noise) * (0.5 + 1.2 * level) * rim;
            }

            // A polar starfield: rings of cells, each ring turning at its own rate (inner faster), so the field shears
            // without tearing. `bias` thickens it (and brightens it) where the arms are.
            static float vortexMetalStars(float2 p, float radius, float rotation, float time, float seed, float count, float rings, float bias) {
                float r = length(p) + 1e-4;
                float rho = r / radius;
                if (rho > 1.5) return 0.0;
                float ring = floor(rho * rings);
                float ringRho = (ring + 0.5) / rings;
                float spin = rotation * (1.7 - ringRho) * 0.6 + hash11(ring + seed) * 6.28;
                float turn = (atan2(p.y, p.x) - spin) / 6.2831853 * count * (0.4 + ringRho);
                float cell = floor(turn);
                float h = hash21(float2(cell, ring + seed));
                float2 jitter = float2(hash21(float2(cell + 3.1, ring)), hash21(float2(cell, ring + 7.7)));
                float dTheta = (fract(turn) - (0.2 + 0.6 * jitter.x)) * 6.2831853 / (count * (0.4 + ringRho)) * r;
                float dRadius = (fract(rho * rings) - (0.2 + 0.6 * jitter.y)) * radius / rings;
                float star = exp(-(dTheta * dTheta + dRadius * dRadius) * 14000.0) * step(1.0 - bias, h);
                return star * (0.35 + 0.65 * hash21(float2(cell + 1.7, ring))) * (0.5 + 0.5 * sin(time * 1.6 + h * 60.0));
            }

            // One bead of light: the band `j` on arm `arm`, shaded as a ball.
            static float3 vortexMetalBead(
                float2 p, int j, int arm, float radius, float rotation, float twist, float m, float kick, float laser,
                constant IntenseUniforms &u, constant float *spectrum, constant float *aux, float3 light) {
                float t = float(j) / 63.0;
                float level = pow(spectrum[j], 0.8);
                float rho = vortexMetalRadius(t) + 0.07 * spectrum[j];
                float a = vortexMetalAngle(t, arm, rotation, twist);
                float2 c = float2(cos(a), sin(a)) * rho * radius;
                float size;
                float3 tint;
                if (j < 10) {
                    size = 0.008 + level * 0.030 * (1.0 + 0.5 * kick);
                    tint = mix(u.c0.rgb, float3(1.0), 0.25);
                } else if (j < 36) {
                    size = 0.008 + level * 0.030;
                    tint = mix(u.c1.rgb, float3(1.0), 0.25);
                } else {
                    size = 0.007 + level * 0.020 * (1.0 + laser);
                    tint = mix(u.c2.rgb, float3(1.0), 0.65);
                }
                float3 bead = fxBall((p - c) / size, light, tint) * (0.5 + 0.6 * level);
                // The glow around it, and the peak-hold tick just outside.
                float d = length(p - c);
                bead += tint * exp(-d * d / (size * size * 5.0)) * 0.22 * level;
                float peakRho = vortexMetalRadius(t) + 0.07 * aux[j];
                float2 pc = float2(cos(a), sin(a)) * (peakRho * radius + 0.012);
                bead += float3(1.0) * exp(-dot(p - pc, p - pc) * 90000.0) * step(spectrum[j] + 0.08, aux[j]) * 0.7;
                return bead;
            }

            fragment float4 vortexMetalFragment(
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
                float beatPulse = pow(1.0 - beatPhase, 2.0);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.03 * intensity;
                float radius = 0.86 * max(aspect, 1.0) * 0.8;
                radius = min(radius, 1.0 * max(aspect, 1.0) * 0.62 + 0.3);
                float r = length(p);
                float a = atan2(p.y, p.x);
                float rho = r / radius;
                float rotation = travel * 0.5236 + beatPulse * 0.03 * intensity;
                float twist = 0.95 + 0.4 * drop + 0.18 * u.wobble.x;
                float3 light = fxKeyLight();
                float3 col = float3(0.002, 0.004, 0.012);

                // Far: a differentially rotating starfield, inner stars faster, twinkling with the highs.
                {
                    float far = vortexMetalStars(p, radius, rotation, time, 1.0, 60.0, 16.0, 0.12);
                    float near = vortexMetalStars(p, radius, rotation, time * 1.4, 9.0, 24.0, 8.0, 0.06 + 0.08 * highs);
                    col += mix(u.c2.rgb, float3(1.0), 0.6) * (far * 0.55 + near * (0.9 + 1.6 * highs));
                }

                // Mid: the arms as lit gas, hue turning around the galaxy.
                float e = 0.008;
                float g0 = vortexMetalGas(p, radius, rotation, twist, time, spectrum);
                float gx = vortexMetalGas(p + float2(e, 0.0), radius, rotation, twist, time, spectrum);
                float gy = vortexMetalGas(p + float2(0.0, e), radius, rotation, twist, time, spectrum);
                float3 n = fxNormal(g0, gx, gy, e, 0.35);
                float2 shade = fxLight(n, light, 18.0);
                float3 hue = paletteAt(u, a / 6.2831853 + 0.5 + rotation * 0.05 + 0.1 * rho);
                float lit = smoothstep(0.02, 0.5, g0);
                float cluster = vortexMetalStars(p, radius, rotation * 1.02, time, 21.0, 90.0, 28.0, 0.55) * smoothstep(0.05, 0.4, g0);
                col += mix(hue, float3(1.0), 0.6) * cluster * 1.4;
                float3 gas = hue * (0.15 + 0.85 * shade.x) * g0 * 2.3 + float3(1.0) * shade.y * g0 * 0.35;
                col += gas * (0.8 + 0.4 * energy);
                // A faint dust haze between the arms so the disc reads as a body.

                // Glitch: the arms split into two optical fringes.
                float glitch = u.extra.w;
                if (glitch > 0.05) {
                    float shift = glitch * 0.02;
                    float ga = vortexMetalGas(p + float2(shift, 0.0), radius, rotation, twist, time, spectrum);
                    float gb = vortexMetalGas(p - float2(shift, 0.0), radius, rotation, twist, time, spectrum);
                    col += (u.c2.rgb * ga + u.c0.rgb * gb) * 0.35 * glitch;
                }

                // Near: a bead of light on every band of the nearest arm, tiered by range.
                {
                    float t = vortexMetalBandAt(rho);
                    int bestArm = 0;
                    float bestD = 10.0;
                    for (int arm = 0; arm < 3; arm++) {
                        float d = abs(vortexMetalWrap(a - vortexMetalAngle(t, arm, rotation, twist)));
                        if (d < bestD) {
                            bestD = d;
                            bestArm = arm;
                        }
                    }
                    int j = clamp(int(t * 63.0 + 0.5), 0, 63);
                    float frac = t * 63.0 + 0.5 - float(j);
                    int k = clamp(j + (frac > 0.5 ? 1 : -1), 0, 63);
                    float3 beads = vortexMetalBead(p, j, bestArm, radius, rotation, twist, 1.0, kick, u.env.w, u, spectrum, aux, light);
                    beads += vortexMetalBead(p, k, bestArm, radius, rotation, twist, 1.0, kick, u.env.w, u, spectrum, aux, light);
                    col += beads * smoothstep(1.05, 0.9, rho) * 1.1;
                }

                // The accretion ring: the waveform wrapped around the core, breathing with the bass and the kick.
                float coreR = 0.045 + 0.07 * bass + 0.05 * kick;
                {
                    float ringR = coreR + 0.075;
                    float turn = fract(a / 6.2831853 + rotation * 0.08);
                    float w = wave[int(turn * 511.0)];
                    float rw = ringR * (1.0 + 0.2 * w * (0.6 + mids));
                    float2 beam = fxBeam(abs(r - rw), 0.004 + 0.004 * kick);
                    col += (mix(u.c2.rgb, float3(1.0), 0.3) * beam.y * 1.6 + mix(u.c2.rgb, float3(1.0), 0.7) * beam.x) * (0.35 + 0.4 * u.wobble.z);
                }

                // Rings: a snare shock ring thrown out of the core and a faint ring leaving on every beat.
                {
                    float shockR = radius * (0.14 + 1.0 * (1.0 - snare));
                    float shock = exp(-pow((r - shockR) / (0.012 + 0.03 * snare), 2.0)) * snare;
                    col += mix(u.c1.rgb, float3(1.0), 0.3) * shock * 0.75;
                    float beatR = radius * (0.14 + 0.5 * beatPhase);
                    col += u.c2.rgb * exp(-pow((r - beatR) * 60.0, 2.0)) * (1.0 - beatPhase) * (1.0 - beatPhase) * 0.2;
                }

                // The hot core: an orb that breathes with the bass and jumps on the kick.
                {
                    float3 core = mix(u.c0.rgb, float3(1.0), 0.55);
                    col += core * exp(-r * r / (coreR * coreR * 0.8)) * (0.7 + 0.5 * beatPulse * intensity);
                    col += u.c1.rgb * exp(-r * r / (coreR * coreR * 10.0)) * 0.22 * (0.5 + bass);
                }

                col = fxFlash(col, u, 0.25);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
