#if canImport(Metal)
    /// A lensed black hole: a swirling accretion disk arching over the shadow, a photon ring and drop-fired jets. Promoted from the SoundGallery drop-in plugin `blackhole.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum BlackHoleShader {
        static let source = #"""
            // title: Black hole
            // fragment: blackHoleFragment

            // A black hole seen from just above its accretion disk. The disk is a broad, swirling vortex of hot gas, wound into
            // soft spiral arms and turning faster toward the centre; its near side passes in front of the shadow and its far
            // side, bent by gravity, arches up over the top (and a thin sliver under the bottom). A crisp photon ring hugs the
            // shadow, the stars and nebula behind are lensed around it, and streams of matter spiral in.
            //
            // The music: each radius of the disk follows one spectrum band (bass at the inner edge, highs at the rim), bass
            // heats the gas, a kick swells the shadow and flashes the photon ring, a snare sends a shockwave out through the
            // disk, each beat a bright clump spirals in from the rim, hats sparkle the infalling streams, energy spins it up,
            // the drop zooms in and fires the polar jets.
            //
            // Colour: every hue comes from one heat ramp. With a palette look active (u.extra.y) the ramp is the palette
            // (c0 cool outer gas -> c1 -> c2 hottest -> white); without one it is blackbody (red -> orange -> gold -> white).

            static float3 bhRamp(float x, constant IntenseUniforms &u) {
                x = max(x, 0.0);
                float3 warm = float3(0.55, 0.06, 0.01) * smoothstep(0.0, 0.25, x);
                warm = mix(warm, float3(1.0, 0.38, 0.05), smoothstep(0.15, 0.5, x));
                warm = mix(warm, float3(1.0, 0.75, 0.32), smoothstep(0.45, 0.85, x));
                warm = mix(warm, float3(1.0, 0.95, 0.85), smoothstep(0.8, 1.3, x));
                float3 pal = mix(u.c0.rgb * 0.35, u.c0.rgb, smoothstep(0.0, 0.3, x));
                pal = mix(pal, u.c1.rgb, smoothstep(0.2, 0.5, x));
                pal = mix(pal, u.c2.rgb, smoothstep(0.5, 0.85, x));
                pal = mix(pal, mix(u.c2.rgb, float3(1.0), 0.5), smoothstep(1.1, 1.8, x));
                float3 c = mix(warm, pal, u.extra.y);
                return c * (0.35 + 0.65 * smoothstep(0.0, 0.5, x)) * (0.8 + 0.6 * x);
            }

            struct BHDisk {
                float inner;
                float outer;
                float spin;
                float t;
                float beats;
                float bass;
                float energy;
                float kick;
                float snare;
            };

            // The disk's light at disk-plane point q (shadow radius units are already folded into inner/outer): rgb is light,
            // a is coverage.
            static float4 bhDisk(float2 q, thread const BHDisk &d, constant float *spectrum, constant IntenseUniforms &u) {
                float rd = length(q) + 1e-5;
                if (rd < d.inner * 0.9 || rd > d.outer * 1.15) return float4(0.0);
                float a = atan2(q.y, q.x);
                float lr = log(rd / d.inner);
                // Differential rotation: the inside whips round, the outside drifts.
                float rot = d.t * d.spin * 0.8 * pow(d.inner / rd, 1.5);
                float ar = a - rot;
                // Soft spiral arms: the gas is wound along a log spiral.
                float wind = ar + 1.8 * lr;
                float2 cs = float2(cos(wind), sin(wind));
                float3 sq = float3(cs * 1.6, lr * 2.2 - d.t * 0.08);
                float2 warp = float2(fxFbm3(sq + float3(0.0, 0.0, 3.1), 3), fxFbm3(sq + float3(5.7, 1.9, 0.0), 3)) - 0.5;
                float gas = fxFbm3(sq * 1.4 + float3(warp * 1.8, d.t * 0.05 * (1.0 + d.energy)), 4);
                float arms = 0.5 + 0.5 * cos(3.0 * wind + 1.5 * (gas - 0.5) * 6.2831853);
                float x = saturate((rd - d.inner) / (d.outer - d.inner));
                float band = bandAt(spectrum, x * 0.85 + 0.03);
                // A snare shockwave and a kick flare running outward.
                float shock = d.snare * exp(-pow((rd - mix(d.inner, d.outer, 1.0 - d.snare)) / (d.inner * 0.18), 2.0));
                float flare = d.kick * exp(-pow((rd - mix(d.inner, d.outer * 0.8, 1.0 - d.kick)) / (d.inner * 0.35), 2.0));
                // Each beat a bright clump spirals in from the rim.
                float bf = fract(d.beats);
                float br = mix(d.outer * 0.9, d.inner * 1.1, bf * bf);
                float ba = floor(d.beats) * 2.4 + d.t * d.spin * 0.8 * pow(d.inner / br, 1.5) + 2.0 * bf;
                float2 bp = br * float2(cos(ba), sin(ba));
                float clump = exp(-dot(q - bp, q - bp) / pow(d.inner * (0.3 + 0.25 * (1.0 - bf)), 2.0)) * (0.5 + bf);
                // Doppler beaming: the gas comes toward us on the left.
                float dop = 1.0 + 0.5 * (-q.x / rd) * sqrt(d.inner / rd);
                float beam = dop * dop * dop;
                float heat = pow(d.inner / rd, 1.25) * (0.75 + 0.4 * d.bass) + 0.25 * band + 0.45 * shock + 0.5 * flare + 0.6 * clump;
                heat *= mix(0.8, 1.2, saturate(dop - 0.5));
                float dens = smoothstep(d.inner * 0.95, d.inner * 1.12, rd) * smoothstep(d.outer * 1.15, d.outer * 0.55, rd);
                dens *= (0.4 + 0.7 * gas) * (0.75 + 0.35 * arms);
                float3 light = bhRamp(heat, u) * dens * (0.55 + 0.7 * band + shock + flare + clump * 1.4) * beam;
                return float4(light, saturate(dens * 1.3));
            }

            static float3 bhBackground(float2 q, float t, float hat, constant IntenseUniforms &u) {
                float3 col = float3(0.0);
                float neb = fxFbm3(float3(q * 1.2, 0.3), 5);
                float3 nebTint = mix(u.c0.rgb, u.c2.rgb, smoothstep(0.3, 0.7, fxNoise3(float3(q * 0.8, 2.0))));
                col += nebTint * pow(neb, 3.5) * 0.03;
                for (int layer = 0; layer < 2; layer++) {
                    float2 c;
                    float h;
                    float cs = layer == 0 ? 0.025 : 0.07;
                    float2 qq = q + float(layer) * 9.3;
                    if (fxCell(qq, cs, 7.0 + float(layer) * 4.0, layer == 0 ? 0.35 : 0.22, c, h)) {
                        float size = cs * (layer == 0 ? 0.07 : 0.08) * (0.6 + h);
                        float d = length(qq - c);
                        float tw = 0.7 + 0.3 * sin(t * (1.0 + 2.0 * h) + h * 50.0) + 0.35 * hat;
                        float3 tint = mix(float3(1.0, 0.9, 0.8), mix(float3(0.75, 0.85, 1.0), u.c2.rgb, 0.3 * u.extra.y), fract(h * 23.0));
                        col += tint * exp(-d * d / (size * size)) * tw * (layer == 0 ? 0.8 : 1.4);
                    }
                }
                return col;
            }

            fragment float4 blackHoleFragment(
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
                float px = 2.0 / max(u.resTime.y, 1.0);
                float zoom = 1.0 + 0.18 * drop + 0.04 * bass;
                // A slow roll and drift, so the view is never quite still.
                float roll = 0.18 * sin(t * 0.06) - 0.08;
                float2 sp = float2(p.x, -p.y) / zoom;
                sp = float2(cos(roll) * sp.x - sin(roll) * sp.y, sin(roll) * sp.x + cos(roll) * sp.y);
                sp -= float2(0.04 * sin(t * 0.05), 0.03 * sin(t * 0.07));
                px /= zoom;

                float Rs = 0.23 * (1.0 + 0.07 * kick + 0.02 * bass);
                float r = length(sp) + 1e-5;
                float2 dir = sp / r;
                // The view sits just above the disk plane; it rocks gently up and down.
                float el = 0.3 + 0.07 * sin(t * 0.083);
                float sinEl = sin(el);

                BHDisk disk;
                disk.inner = Rs * 1.45;
                disk.outer = Rs * 6.0;
                disk.spin = 1.0 + 0.7 * energy + 1.0 * drop;
                disk.t = t;
                disk.beats = beats;
                disk.bass = bass;
                disk.energy = energy;
                disk.kick = kick;
                disk.snare = snare;

                // ---- Behind: the lensed sky -----------------------------------------------------------------------------
                float deflect = Rs * Rs * 1.7 / r;
                float2 bq = sp - dir * deflect * 1.0 + float2(t * 0.004, 0.0);
                float3 col = bhBackground(bq * 1.6, t, hat, u);
                // The Einstein ring: lensed starlight piles up just outside the photon ring.
                col += bhRamp(0.5, u) * 0.06 * exp(-pow((r - Rs * 1.55) / (Rs * 0.25), 2.0));

                // ---- The far half of the disk (behind the hole) ---------------------------------------------------------
                float2 q = float2(sp.x, sp.y / sinEl);
                float4 far = sp.y > 0.0 ? bhDisk(q, disk, spectrum, u) : float4(0.0);
                col = col * (1.0 - far.a) + far.rgb;

                // ---- The far side again, bent up over the top of the shadow (and a sliver under it) ------------------------
                float phi = atan2(sp.y, sp.x);
                float s = sin(phi);
                float archW = Rs * mix(0.15, 1.05, pow(saturate(s), 0.7)) + Rs * 0.14 * saturate(-s);
                float archX = (r - Rs * 1.04) / archW;
                if (archX > 0.0 && archX < 1.4) {
                    // Map the arch back onto the disk: across the arch is outward across the disk, along it is round it.
                    float rr = mix(disk.inner, disk.outer * 0.75, saturate(archX));
                    float2 aq = rr * float2(cos(phi), s > 0.0 ? sin(phi) * -1.0 : sin(phi));
                    float4 arch = bhDisk(aq, disk, spectrum, u);
                    float fade = smoothstep(0.0, 0.08, archX) * smoothstep(1.4, 0.7, archX) * (s > 0.0 ? 1.0 : 0.6);
                    col = col * (1.0 - arch.a * fade) + arch.rgb * fade * 1.5;
                }

                // ---- The shadow and the photon ring ---------------------------------------------------------------------
                float shadow = smoothstep(Rs * 0.995, Rs * 1.01, r);
                col *= shadow;
                float ringW = max(Rs * 0.014, px * 1.3);
                float ring = exp(-pow((r - Rs * 1.02) / ringW, 2.0));
                float ringGlow = exp(-max(r - Rs, 0.0) / (Rs * 0.12)) * shadow;
                float ringBright = (1.0 + 1.4 * kick + 0.6 * snare) * (1.0 + 0.6 * (-dir.x));  // beamed brighter on the left
                col += bhRamp(1.15, u) * ring * ringBright * 1.2 + bhRamp(0.8, u) * ringGlow * ringBright * 0.35;

                // ---- Polar jets on the drop (behind the near disk) ------------------------------------------------------
                if (drop > 0.01) {
                    float ay = abs(sp.y);
                    float w = Rs * (0.12 + 0.35 * max(ay - Rs, 0.0));
                    float jd = exp(-sp.x * sp.x / (w * w)) * smoothstep(Rs * 0.9, Rs * 1.6, ay) * exp(-ay * 0.8);
                    float knots = 0.55 + 0.45 * fxNoise3(float3(sp.x * 30.0, ay * 6.0 - t * 5.0, 1.0));
                    col += mix(float3(0.5, 0.7, 1.0), u.c2.rgb, u.extra.y) * jd * knots * drop * 1.4 * shadow;
                }

                // ---- The near half of the disk (in front of the hole) ---------------------------------------------------
                float4 nearD = sp.y <= 0.0 ? bhDisk(q, disk, spectrum, u) : float4(0.0);
                col = col * (1.0 - nearD.a) + nearD.rgb;

                // ---- Streams of matter spiralling in (in the disk plane), sparkling with the hats -----------------------
                float qr = length(q) + 1e-5;
                if (qr > disk.inner && qr < disk.outer * 1.3) {
                    float qa = atan2(q.y, q.x);
                    float lr = log(qr / disk.inner);
                    // Log-polar cells, flowing inward and around.
                    float2 lp = float2(qa * 3.0 / 6.2831853 * 6.0 + t * disk.spin * 0.35 / (0.3 + lr), lr * 5.0 + t * 0.6);
                    float2 c;
                    float h;
                    if (fxCell(lp, 1.0, 19.0, 0.22, c, h)) {
                        float2 dd = (lp - c) * float2(0.35, 1.6);  // streaks drawn out along the orbit
                        float e = exp(-dot(dd, dd) * 18.0);
                        float tw = 0.4 + 0.6 * h + 1.5 * hat + 0.5 * highs;
                        float behind = (sp.y > 0.0 && r < Rs * 1.05) ? 0.0 : 1.0;
                        col += bhRamp(0.75 + 0.4 * h, u) * e * tw * 0.18 * behind * smoothstep(disk.outer * 1.3, disk.outer * 0.5, qr);
                    }
                }

                float2 pix = in.uv * u.resTime.xy;
                float dither = fract(52.9829189 * fract(dot(pix, float2(0.06711056, 0.00583715))));
                col += (dither - 0.5) / 255.0;
                col = fxFlash(col, u, 0.3);
                col *= 0.95;
                col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
                col = fxVignette(col, p, 0.12);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
