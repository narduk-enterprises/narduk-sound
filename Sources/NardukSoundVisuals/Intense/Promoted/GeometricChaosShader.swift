#if canImport(Metal)
    /// A checkered polygon tunnel, a fractal core re-seeded each beat and counter-spinning polygon rings. Promoted from the SoundGallery drop-in plugin `chaos.metal` (narduk-libs#1569); the MSL is the plugin's,
    /// unchanged, so the plugin and the built-in draw the same picture.
    enum GeometricChaosShader {
        static let source = #"""
            // title: Geometric chaos
            // fragment: chaosFragment

            // Dense, relentless geometry: a kaleidoscopic tunnel of lines and triangles hurtling toward you, a fractal fold
            // that writhes and re-forms, and rings of nested polygons zooming out of the centre, each spinning against the
            // next. The kick punches everything in and throws a shock ring, the snare flips every spin and re-cuts the
            // symmetry, each bar picks a new symmetry, hats jitter and sparkle the lines, bass thickens them, energy and the
            // drop drive the speed and split the colour channels apart. The motion is in the geometry, not in full-screen
            // flashes: the only flash is the app's rationed one. Colour: every layer is drawn from the palette.

            struct ChaosDrive {
                float t;
                float beats;
                float kick;
                float snare;
                float hat;
                float bass;
                float energy;
                float drop;
                float spinSign;
                float sym;
                float px;
            };

            static float2 chaosRot(float2 v, float a) {
                float c = cos(a);
                float s = sin(a);
                return float2(c * v.x - s * v.y, s * v.x + c * v.y);
            }

            // Distance to a regular n-gon of circumradius r.
            static float chaosPoly(float2 p, float n, float r) {
                float an = 3.14159265 / n;
                float a = atan2(p.y, p.x);
                float sector = fmod(a + 3.14159265 * 8.0, 2.0 * an) - an;
                return length(p) * cos(sector) - r * cos(an);
            }

            static float chaosLine(float d, float w, float px) {
                w = max(w, px * 1.2);
                return exp(-d * d / (w * w));
            }

            static float3 chaosField(float2 p, thread const ChaosDrive &d, constant IntenseUniforms &u, constant float *spectrum) {
                float3 col = float3(0.0);
                float r = length(p) + 1e-4;
                float a = atan2(p.y, p.x);
                float speed = 1.0 + 1.6 * d.energy + 2.5 * d.drop;
                float thick = 1.0 + 1.2 * d.bass + 1.5 * d.kick;

                // ---- The tunnel: kaleidoscope-folded lines and triangles rushing outward -----------------------------------
                // A polygonal tunnel: the radius is measured to a d.sym-gon, so the walls are flat faces, and the walls are a
                // checkerboard of tiles rushing at the viewer. Alternate tiles are lit; their edges glow.
                float seg = 6.2831853 / d.sym;
                float sa = a + d.t * 0.35 * d.spinSign;
                float sector = fmod(sa + 6.2831853 * 8.0, seg) - seg * 0.5;
                float pr = r * cos(sector) / cos(seg * 0.5);
                float depth = 0.42 / max(pr, 1e-3) + d.t * 1.4 * speed + d.beats * 0.5;
                float across = (sa / seg + 64.0) * 2.0;
                float2 tile = float2(across, depth);
                float2 tid = floor(tile);
                float2 tf = fract(tile) - 0.5;
                float checker = fmod(tid.x + tid.y + 200.0, 2.0);
                float edge = 0.5 - abs(tf.y);
                // The edge width in tile units grows with depth density, so far tiles do not alias into mush.
                float tpx = d.px * 0.42 / max(pr * pr, 1e-3);
                float tedge = chaosLine(edge, 0.03 * thick, tpx * 1.5);
                float fade = smoothstep(0.05, 0.3, r) * smoothstep(3.0, 0.4, tpx * 60.0);
                float th = hash21(tid + floor(d.beats));
                float lit = checker * (0.18 + 0.9 * step(0.8, th) * (0.4 + d.kick));
                float3 tcol = paletteAt(u, fract(th * 0.5 + tid.y * 0.07 + d.beats * 0.125));
                col += tcol * (lit + tedge * (0.7 + 0.8 * bandAt(spectrum, fract(tid.x * 0.13) * 0.8 + 0.05))) * fade;

                // ---- The fractal fold: a writhing kaliset, re-seeded each beat ---------------------------------------------
                float2 fq = chaosRot(p * (1.3 - 0.35 * d.kick), d.t * 0.15 * d.spinSign);
                float beatPhase = fract(d.beats);
                float seed = floor(d.beats);
                float2 c = float2(0.55 + 0.18 * sin(seed * 1.7 + d.t * 0.3), 0.42 + 0.18 * cos(seed * 2.3 + d.t * 0.25));
                c += 0.05 * float2(sin(d.t * 3.0), cos(d.t * 2.6)) * d.hat;
                float trap = 1e3;
                float trap2 = 1e3;
                for (int i = 0; i < 9; i++) {
                    fq = abs(fq) / max(dot(fq, fq), 0.02) - c;
                    trap = min(trap, abs(fq.x * fq.y));
                    trap2 = min(trap2, abs(length(fq) - 0.6));
                }
                float frac = exp(-trap * 40.0) * 0.9 + exp(-trap2 * 60.0) * 0.6;
                frac *= smoothstep(0.9, 0.1, r) * (0.3 + 0.7 * d.kick);
                col += paletteAt(u, fract(trap2 * 2.0 + d.t * 0.05 + 0.33)) * frac;

                // ---- Rings of nested polygons zooming out, each spinning against the last ---------------------------------
                float lr = log(r) * 2.2 - d.t * 0.8 * speed - d.kick * 0.6;
                float ringIdx = floor(lr);
                float ringPhase = fract(lr);
                for (int k = 0; k < 2; k++) {
                    float idx = ringIdx - float(k);
                    float sides = 3.0 + fmod(abs(idx) + floor(d.beats / 4.0), 5.0);
                    float rad = exp((idx + 1.0) / 2.2 + d.t * 0.8 * speed / 2.2 + d.kick * 0.6 / 2.2) * 0.5;
                    float spin = d.t * (0.6 + 0.25 * fmod(abs(idx), 3.0)) * (fmod(abs(idx), 2.0) < 1.0 ? 1.0 : -1.0) * d.spinSign;
                    float dp = abs(chaosPoly(chaosRot(p, spin + idx * 0.7), sides, rad));
                    float w = 0.008 * thick * rad * 4.0;
                    float pl = chaosLine(dp, w, d.px) * smoothstep(0.03, 0.12, r);
                    col += paletteAt(u, fract(idx * 0.21 + 0.6)) * pl * 1.8;
                }

                // ---- The kick's shock ring and the snare's starburst ------------------------------------------------------
                float shockR = 0.08 + (1.0 - d.kick) * 1.4;
                col += mix(u.c2.rgb, float3(1.0), 0.4) * chaosLine(r - shockR, 0.012 + 0.03 * d.kick, d.px) * d.kick * 1.3;
                float rays = pow(abs(cos(a * d.sym * 0.5 + d.t * 2.0 * d.spinSign)), 60.0);
                col += u.c1.rgb * rays * d.snare * smoothstep(0.6, 0.0, r) * 0.6;
                // Bursts: small cells all over the frame fire on the beat grid and the hats; each covers a sliver of the
                // screen, so the frame glitters without strobing as a whole.
                float2 bc;
                float bh;
                if (fxCell(p * 3.0 + float2(d.t * 0.2, 0.0), 1.0, floor(d.beats * 2.0) * 1.3, 0.25, bc, bh)) {
                    float bd = abs(chaosPoly(chaosRot(p * 3.0 - bc, d.t * 3.0 * (bh - 0.5)), 3.0 + floor(bh * 4.0), 0.18 + 0.1 * d.kick));
                    float pulse = exp(-fract(d.beats * 2.0 + bh) * 5.0) * (0.6 + 1.4 * d.hat + d.kick);
                    col += paletteAt(u, bh) * chaosLine(bd, 0.02, d.px * 3.0) * pulse * 1.4;
                }

                // A hat sparkle along everything bright.
                float spark = smoothstep(0.86, 0.98, fxNoise3(float3(p * 40.0, d.t * 6.0)));
                col += float3(1.0) * spark * d.hat * dot(col, float3(0.33)) * 1.2;
                return col;
            }

            fragment float4 chaosFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                ChaosDrive d;
                d.t = u.resTime.z * mix(0.4, 1.0, intensity);
                d.beats = u.resTime.w;
                d.kick = u.env.x * intensity;
                d.snare = u.env.y * intensity;
                d.hat = u.env.z * intensity;
                d.energy = u.wobble.z;
                d.drop = u.misc.y;
                d.bass = bandAt(spectrum, 0.05);
                // The snare flips the spin: count the beats and flip on every second one, smoothed so it whips, not snaps.
                float flip = sin(3.14159265 * floor(d.beats * 0.5)) * 0.0 + (fmod(floor(d.beats * 0.5), 2.0) < 1.0 ? 1.0 : -1.0);
                d.spinSign = flip;
                // Each bar picks a new symmetry.
                float bar = floor(d.beats / 4.0);
                d.sym = 5.0 + 2.0 * fmod(bar, 4.0);
                d.px = 2.0 / max(u.resTime.y, 1.0);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                // The whole frame punches in on the kick and wobbles.
                float punch = 1.0 - 0.2 * d.kick - 0.06 * d.bass;
                p *= punch;
                p = chaosRot(p, 0.08 * sin(d.t * 0.7) + 0.06 * d.snare * d.spinSign);
                p += 0.015 * float2(sin(d.t * 5.3), cos(d.t * 4.7)) * d.kick;

                // The colour channels split apart with energy and the drop.
                float split = 0.004 + 0.012 * d.energy + 0.025 * d.drop + 0.01 * d.kick;
                float3 cr = chaosField(p * (1.0 + split), d, u, spectrum);
                float3 cg = chaosField(p, d, u, spectrum);
                float3 cb = chaosField(p * (1.0 - split), d, u, spectrum);
                float3 col = float3(cr.r, cg.g, cb.b);
                // Hard contrast: deep blacks between neon lines.
                col = pow(max(col, 0.0), float3(1.35)) * 1.6;

                // A dim palette glow underneath, breathing with the bass (slow: never a strobe).
                float r = length(p);
                col += mix(u.c0.rgb, u.c2.rgb, 0.5) * 0.02 * (0.6 + 0.6 * d.bass) * exp(-r * 1.5);

                col = fxFlash(col, u, 0.3);
                col = fxTonemap(col, 1.15);
                col = fxVignette(col, (in.uv - 0.5) * float2(aspect, 1.0) * 2.0, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
