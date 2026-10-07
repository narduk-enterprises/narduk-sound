#if canImport(Metal)
    /// Jellyfish: a small swarm of translucent moon jellies swimming in the deep, near and far. Each bell is a real 3-D
    /// volume, marched through, so it glows like glass: clear and faintly mottled at the crown, bright where the eye
    /// looks along the shell at its rim, with sixteen radial canals, a ring canal, four horseshoe gonads, a fringe of
    /// fine marginal tentacles and bioluminescent lights around a scalloped margin. Long trailing tentacles and four
    /// frilled oral arms hang below each bell in 3-D (front ones pass in front of it, back ones are seen through it)
    /// with depth blur. God rays fall from the surface and marine snow drifts through two depths.
    ///
    /// The music swims them: on the beat the bells contract hard (crown first, the margin a moment later), lift, and
    /// the stroke travels down the tentacles as a wave; some jellies stroke every beat, some every other. A kick snaps
    /// an extra stroke and flashes the bells; bass swells them and their glow; each canal is one spectrum band, so an
    /// equaliser runs around every bell; a snare ripples the margins and fires the rim lights; hats sparkle the rim
    /// lights and the snow; the drop deepens the glow. The palette tints each jelly (shell from c2 and a palette hue,
    /// gonads and arms from c1, water from c0). Calm slows everything and softens the strokes and flashes.
    enum JellyfishShader {
        static let source = #"""
            constant int kJellies = 5;
            // Per jelly: bell radius, depth, home (x, y), stroke rate (strokes per beat), stroke offset (beats).
            constant float kJellySize[5] = {0.30, 0.22, 0.17, 0.25, 0.13};
            constant float kJellyDepth[5] = {0.25, -1.1, -2.4, -0.4, 0.75};
            constant float kJellyHome[5] = {-0.2, 1.15, -1.5, 0.6, -0.95};
            constant float kJellyHomeY[5] = {0.45, 0.85, 1.05, -0.05, -0.2};
            constant float kJellyRate[5] = {1.0, 0.5, 0.5, 1.0, 0.5};
            constant float kJellyOffset[5] = {0.0, 0.0, 1.0, 0.0, 1.0};

            struct JellyCamera {
                float3 ro;
                float3 fw;
                float3 rt;
                float3 up;
                float fl;
            };

            // Screen position (same units as the pixel's p) of world point `w`, and its depth along the view in z.
            static float3 jellyProject(thread const JellyCamera &cam, float3 w) {
                float3 d = w - cam.ro;
                float z = max(dot(d, cam.fw), 0.05);
                return float3(float2(dot(d, cam.rt), dot(d, cam.up)) * cam.fl / z, z);
            }

            // One swim stroke over a 0...1 cycle: a hard, quick contraction, then a long relaxation.
            static float jellyStroke(float t) {
                t = fract(t);
                return smoothstep(0.0, 0.09, t) * exp(-max(t - 0.09, 0.0) * 4.5);
            }

            static float2 jellyRotate(float2 v, float a) {
                float c = cos(a);
                float s = sin(a);
                return float2(c * v.x - s * v.y, s * v.x + c * v.y);
            }

            struct JellyBody {
                float3 center;
                float tilt;      // lean about the view axis
                float spin;      // slow turn about its own vertical axis
                float a;         // bell radius
                float b;         // bell height above the equator
                float swim;      // the stroke clock (cycles)
                float strength;  // how hard a stroke contracts
                float kick;
                float snare;
                float time;
                float hue;       // 0...1, this jelly's palette position
                float glow;      // emission scale, flashes included
            };

            static float3 jellyLocal(thread const JellyBody &j, float3 w) {
                float3 q = w - j.center;
                q.xy = jellyRotate(q.xy, -j.tilt);
                q.xz = jellyRotate(q.xz, -j.spin);
                return q;
            }

            static float3 jellyWorld(thread const JellyBody &j, float3 q) {
                q.xz = jellyRotate(q.xz, j.spin);
                q.xy = jellyRotate(q.xy, j.tilt);
                return q + j.center;
            }

            // The contraction at normalised height yn (1 crown, 0 margin): the crown leads, the margin follows.
            static float jellyContraction(thread const JellyBody &j, float yn) {
                float stroke = jellyStroke(j.swim - (1.0 - yn) * 0.08) * j.strength;
                return saturate(max(stroke, 0.85 * j.kick));
            }

            // The margin's height and radius at angle phi (bell frame).
            static float2 jellyRim(thread const JellyBody &j, float phi) {
                float c = jellyContraction(j, 0.0);
                float scallop = 0.035 * j.a * cos(phi * 16.0);
                float ripple = 0.07 * j.a * j.snare * sin(phi * 6.0 - j.time * 9.0);
                float rimY = -0.22 * j.b + scallop + ripple + 0.1 * j.b * c;
                float a = j.a * (1.0 - 0.36 * c);
                float b = j.b * (1.0 + 0.18 * c);
                float r = a * sqrt(max(1.0 - (rimY * rimY) / (b * b), 0.0)) * 0.97;
                return float2(rimY, r);
            }

            struct JellyLayer {
                float3 behind;    // tentacles and arms behind the bell, and its halo
                float3 bell;      // the bell's own light
                float transmit;   // how much of what is behind the bell shows through it
                float3 front;     // tentacles and arms in front of the bell
            };

            static JellyLayer jellyDraw(
                thread const JellyBody &j, thread const JellyCamera &cam, float2 sp, float px, float dither,
                float3 shellTint, float3 gonadTint, float3 tentTint, float hat, float highs, float drop,
                constant float *spectrum) {
                JellyLayer out;
                out.behind = float3(0.0);
                out.bell = float3(0.0);
                out.front = float3(0.0);
                out.transmit = 1.0;
                float time = j.time;
                float3 pc = jellyProject(cam, j.center);
                float scale = cam.fl / pc.z;
                float lengthScale = j.a * 4.6;

                // Cheap reject: the pixel is nowhere near this jelly, its tentacles or its halo.
                float reach = (j.a * 2.2 + 0.3 * lengthScale) * scale;
                if (abs(sp.x - pc.x) > reach || sp.y > pc.y + j.a * 2.2 * scale || sp.y < pc.y - (lengthScale + j.a * 1.5) * scale) {
                    return out;
                }

                // A soft glow in the water around the bell.
                float2 halo = (sp - pc.xy) / (j.a * scale);
                out.behind += shellTint * exp(-length(halo * float2(1.0, 1.25)) * 0.9) * 0.05 * j.glow;

                // ---- Tentacles and oral arms in 3-D ---------------------------------------------------------
                const int tentacles = 12;
                for (int i = 0; i < tentacles + 4; i++) {
                    bool arm = i >= tentacles;
                    float fi = float(i);
                    float hi = hash11(fi * 3.17 + j.hue * 41.0 + 1.0);
                    float phi = arm ? (float(i - tentacles) + 0.5) * 1.5707963 + 0.3
                                    : (fi + 0.4 * hi) / float(tentacles) * 6.2831853;
                    float2 rim = jellyRim(j, phi);
                    float anchorR = arm ? 0.13 * j.a : rim.y;
                    float anchorY = arm ? rim.x + 0.18 * j.a : rim.x;
                    float L = (arm ? 1.6 + 0.3 * hi : 2.6 + 1.8 * hi) * j.a;
                    float3 anchor = jellyWorld(j, float3(anchorR * cos(phi), anchorY, anchorR * sin(phi)));
                    float3 pa = jellyProject(cam, anchor);
                    float sc = cam.fl / pa.z;
                    float s = (pa.y - sp.y) / (sc * L);
                    if (s < -0.02 || s > 1.0) continue;
                    s = max(s, 0.0);
                    float2 radial = float2(cos(phi + j.spin), sin(phi + j.spin));
                    float3 pts[2];
                    for (int k = 0; k < 2; k++) {
                        float sk = s + float(k) * 0.02;
                        float wave = jellyStroke(j.swim - 0.1 - sk * 0.45) * j.strength;
                        // Arms are short: they sway gently, or a flat run would smear sideways.
                        float amp = (arm ? 0.05 + 0.12 * sk : 0.12 + 0.7 * sk * sk) * j.a;
                        float speed = arm ? 0.9 : 1.5;
                        float dx = amp * sin(5.0 * sk - time * speed + fi * 1.7) + (arm ? 0.0 : 0.15 * j.a * sin(13.0 * sk - time * 2.3 + fi));
                        float dz = amp * cos(4.1 * sk - time * speed * 0.8 + fi * 2.3);
                        float flare = (arm ? 0.2 * sk * wave : (0.6 * wave - 0.15) * sk) * j.a;
                        float3 w = anchor + float3(dx + radial.x * flare, -sk * L * (1.0 - 0.14 * wave), dz + radial.y * flare);
                        pts[k] = jellyProject(cam, w);
                    }
                    // Clamped: where a strand runs nearly flat the estimate blows up into a horizontal streak.
                    float slope = clamp((pts[1].x - pts[0].x) / max(abs(pts[1].y - pts[0].y), 1e-4), -2.5, 2.5);
                    float dist = abs(sp.x - pts[0].x) / sqrt(1.0 + slope * slope);
                    float near = cam.fl / pts[0].z;
                    float blur = abs(pts[0].z - 3.0) * 0.004;
                    float3 contribution;
                    if (arm) {
                        // Oral arm: a translucent frilled ribbon, lacy ruffled edges over soft folds.
                        float ruffle = 1.0 + 0.3 * sin(s * 37.0 + time * 1.7 + fi) + 0.15 * sin(s * 91.0 - time * 2.9);
                        float w = 0.2 * j.a * (1.0 - 0.55 * s) * ruffle * near + blur + px;
                        float edgeWidth = 0.22 * w + px;
                        float edge = exp(-pow((dist - w) / edgeWidth, 2.0));
                        float inside = smoothstep(w, w * 0.5, dist);
                        float folds = 0.55 + 0.45 * sin(s * 24.0 - time * 1.2 + dist / max(w, 1e-4) * 3.0);
                        float fade = smoothstep(1.0, 0.6, s);
                        float3 armTint = mix(gonadTint, float3(0.95, 0.9, 1.0), 0.35);
                        contribution = armTint * (edge * 0.32 + inside * folds * 0.07) * fade * j.glow;
                    } else {
                        // Tentacle: a fine glowing filament with stinging-cell beads, fading toward the tip. Never
                        // thinner than a pixel (thinner would alias into a broken, blocky line): wider, but fainter.
                        float w0 = (0.008 + 0.008 * (1.0 - s)) * j.a * near + blur;
                        float w = max(w0, px * 0.9);
                        float line = exp(-dist * dist / (w * w)) * (w0 / w);
                        float beads = 0.65 + 0.35 * sin(s * 95.0 - time * 3.0 + fi * 4.0);
                        float fade = pow(1.0 - s, 0.8) * smoothstep(-0.02, 0.03, s);
                        contribution = tentTint * line * beads * fade * 0.9 * j.glow;
                    }
                    if (pts[0].z < pc.z) out.front += contribution; else out.behind += contribution;
                }

                // ---- The bell: march through its glassy volume ----------------------------------------------
                float3 rd = normalize(cam.fw * cam.fl + cam.rt * sp.x + cam.up * sp.y);
                float3 oc = cam.ro - j.center;
                float bound = j.a * 1.45;
                float bb = dot(oc, rd);
                float cc = dot(oc, oc) - bound * bound;
                float disc = bb * bb - cc;
                if (disc <= 0.0) return out;
                float sq = sqrt(disc);
                float t0 = max(-bb - sq, 0.0);
                float t1 = -bb + sq;
                const int steps = 56;
                float dt = (t1 - t0) / float(steps);
                // The shell's soft edge is never thinner than a step, so the march never sees it as dots.
                float edgeSoft = max(0.7 * dt, 0.004 * j.a / 0.3);
                float3 rdLocal = rd;
                rdLocal.xy = jellyRotate(rdLocal.xy, -j.tilt);
                rdLocal.xz = jellyRotate(rdLocal.xz, -j.spin);
                float sparkle = 0.5 + 1.8 * hat + 1.2 * j.snare + 0.8 * highs + 0.6 * drop;
                for (int i = 0; i < steps; i++) {
                    float3 w = cam.ro + rd * (t0 + dt * (float(i) + dither));
                    float3 q = jellyLocal(j, w);
                    float phi = atan2(q.z, q.x);
                    float rr = length(q.xz);
                    float yn = saturate((q.y + 0.25 * j.b) / (1.25 * j.b));
                    float c = jellyContraction(j, yn);
                    float a = j.a * (1.0 - 0.36 * c * (1.0 - 0.4 * yn)) * (1.0 + 0.03 * sin(phi * 3.0 + time * 0.7));
                    float b = j.b * (1.0 + 0.18 * c);
                    float k = length(q / float3(a, b, a));
                    float d = (k - 1.0) * min(a, b);
                    float thick = mix(0.04, 0.16, yn) * j.a;
                    float2 rim = jellyRim(j, phi);
                    float below = rim.x - q.y;
                    float shell = max(abs(d + thick) - thick, below);
                    float density = smoothstep(edgeSoft, -edgeSoft, shell);
                    float mottle = 0.7 + 0.6 * fxNoise3(q / j.a * 7.0 + float3(0.0, time * 0.15, j.hue * 9.0));
                    float tissue = smoothstep(edgeSoft * 0.6, -edgeSoft * 0.6, shell);

                    // Radial canals (one spectrum band each, dimmed when seen edge-on) and the ring canal.
                    float canalIndex = floor(phi / 6.2831853 * 16.0 + 16.5);
                    float band = bandAt(spectrum, fract(canalIndex / 16.0) * 0.85 + 0.05);
                    float canalGap = abs(sin(phi * 8.0)) * rr / 8.0;
                    float canalWidth = max(0.015 * j.a, 0.5 * edgeSoft);
                    float canal = exp(-pow(canalGap / canalWidth, 2.0)) * smoothstep(0.12 * j.a, 0.5 * j.a, rr) * (0.4 + 2.4 * band);
                    float edgeOn = abs(dot(rdLocal, float3(-sin(phi), 0.0, cos(phi))));
                    canal *= saturate(0.15 + 4.0 * edgeOn);
                    float ring = exp(-pow((q.y - rim.x - 0.05 * j.a) / max(0.04 * j.a, edgeSoft), 2.0)) * 1.3;
                    float3 emit = shellTint * (density * (0.16 + 0.3 * yn) * mottle + tissue * (canal * 1.6 + ring));

                    // Four horseshoe gonads on the underside of the crown.
                    float gq = phi - 0.7853982;
                    float sector = gq - 1.5707963 * floor(gq / 1.5707963 + 0.5);
                    float2 local = float2(rr * cos(sector) - 0.28 * a, rr * sin(sector));
                    float horse = abs(length(local) - 0.12 * a);
                    float open = smoothstep(-0.02 * j.a / 0.3, 0.05 * j.a / 0.3, -local.x + 0.05 * a);
                    float gonadWidth = max(0.075 * j.a, edgeSoft);
                    float gonad = exp(-pow(horse / gonadWidth, 2.0)) * exp(-pow((q.y - 0.42 * b) / (0.12 * j.a), 2.0)) * open;
                    emit += gonadTint * gonad * (2.6 + 2.0 * c);

                    // A fringe of fine marginal tentacles hanging from the margin, swaying with the stroke.
                    float fringeLength = 0.5 * j.a * (1.0 - 0.3 * c);
                    if (below > 0.0 && below < fringeLength) {
                        float sway = 0.25 * sin(below / j.a * 9.0 - time * 2.5 + phi * 3.0);
                        float hairGap = abs(sin(phi * 40.0 + sway)) * rr / 40.0;
                        float hairWidth = max(0.006 * j.a, 0.45 * edgeSoft);
                        float hairR = rim.y * (1.0 - 0.12 * below / fringeLength);
                        float shellBand = exp(-pow((rr - hairR) / max(0.03 * j.a, edgeSoft), 2.0));
                        float hair = exp(-pow(hairGap / hairWidth, 2.0)) * shellBand * (1.0 - below / fringeLength);
                        emit += tentTint * hair * 1.4;
                    }

                    // Bioluminescent lights around the margin, one per scallop: hats, snares and highs fire them.
                    float lightPhi = (floor(phi / 6.2831853 * 16.0) + 0.5) / 16.0 * 6.2831853;
                    float3 lp = float3(rim.y * cos(lightPhi), rim.x, rim.y * sin(lightPhi));
                    float lightSize = max(0.035 * j.a, edgeSoft);
                    float3 dl = (q - lp) / lightSize;
                    emit += mix(shellTint, float3(1.0), 0.6) * exp(-dot(dl, dl)) * sparkle * 1.6;

                    out.bell += emit * out.transmit * dt / j.a * 1.9 * j.glow;
                    out.transmit *= exp(-density * dt / j.a * 0.45);
                }
                return out;
            }

            fragment float4 jellyfishFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * mix(0.45, 1.0, intensity);
                float beats = u.resTime.w;
                float kick = u.env.x * intensity;
                float snare = u.env.y * intensity;
                float hat = u.env.z * intensity;
                float energy = u.wobble.z;
                float drop = u.misc.y;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                float2 sp = float2(p.x, -p.y);  // y up
                float px = 2.0 / max(u.resTime.y, 1.0);
                // Interleaved-gradient dither for the march start: smooth, no blotches.
                float2 pix = in.uv * u.resTime.xy;
                float dither = fract(52.9829189 * fract(dot(pix, float2(0.06711056, 0.00583715))));

                float3 water = mix(u.c0.rgb * 0.03, float3(0.001, 0.008, 0.04), 0.6);

                JellyCamera cam;
                cam.ro = float3(0.0, -0.3, 3.0);
                cam.fw = normalize(float3(0.0, -0.05, 0.0) - cam.ro);
                cam.rt = normalize(cross(cam.fw, float3(0.0, 1.0, 0.0)));
                cam.up = cross(cam.rt, cam.fw);
                cam.fl = 2.3;

                // ---- The water: depth gradient, god rays from the surface, marine snow -------------------------
                float depth = saturate(0.5 - 0.5 * sp.y);
                float3 col = mix(water * 2.6 + u.c2.rgb * 0.015, water * 0.45, depth);
                float shafts = fbm(float2(sp.x * 2.2 + sp.y * 0.55 + time * 0.03, time * 0.05));
                shafts = pow(saturate(shafts * 1.5 - 0.35), 2.5) * smoothstep(-1.1, 1.0, sp.y);
                col += mix(u.c2.rgb, float3(0.6, 0.85, 1.0), 0.6) * shafts * (0.11 + 0.05 * bass);
                col += mix(u.c2.rgb, float3(0.8, 0.95, 1.0), 0.6) * exp(-(1.0 - sp.y) * 2.6) * 0.05;
                float3 snowTint = mix(u.c2.rgb, float3(1.0), 0.6);
                for (int layer = 0; layer < 2; layer++) {
                    float fl = float(layer);
                    float cs = layer == 0 ? 0.07 : 0.16;
                    float2 drift = float2(time * (0.008 + 0.01 * fl), time * (0.015 + 0.02 * fl));
                    float2 c;
                    float h;
                    float2 q = sp + drift + fl * 3.7;
                    if (fxCell(q, cs, 31.0 + fl * 7.0, layer == 0 ? 0.35 : 0.2, c, h)) {
                        float size = max((layer == 0 ? 0.003 : 0.009) * (0.5 + h), px * 0.8);
                        float d = length(q - c);
                        float mote = exp(-d * d / (size * size));
                        if (layer == 1) mote *= 0.3;
                        float tw = 0.6 + 0.4 * sin(time * (1.0 + 2.0 * h) + h * 30.0) + 0.7 * hat + 0.4 * highs;
                        col += snowTint * mote * tw * 0.3;
                    }
                }

                // ---- The swarm, drawn far to near ---------------------------------------------------------------
                JellyBody jellies[5];
                float depths[5];
                int order[5];
                for (int i = 0; i < kJellies; i++) {
                    float fi = float(i);
                    float hi = hash11(fi * 7.31 + 2.0);
                    JellyBody j;
                    j.time = time + fi * 13.0;
                    j.a = kJellySize[i] * (1.0 + 0.12 * bass + 0.05 * drop);
                    j.b = 0.76 * j.a;
                    j.swim = beats * kJellyRate[i] * 1.0 + kJellyOffset[i] * kJellyRate[i] + time * 0.015;
                    j.strength = (0.7 + 0.3 * energy + 0.45 * bass) * intensity;
                    j.kick = kick * (0.6 + 0.4 * hi);
                    j.snare = snare;
                    float lift = jellyStroke(j.swim - 0.04) * j.strength;
                    // Wander a slow loop around home, lift on every stroke, lean.
                    j.center = float3(
                        kJellyHome[i] + 0.3 * sin(time * (0.05 + 0.03 * hi) + fi * 2.1),
                        kJellyHomeY[i] + 0.18 * sin(time * (0.04 + 0.02 * hi) + fi * 1.4) + 0.12 * j.a / 0.3 * lift
                            + 0.05 * j.kick,
                        kJellyDepth[i] + 0.2 * sin(time * 0.05 + fi));
                    j.tilt = 0.18 * sin(time * (0.11 + 0.05 * hi) + fi * 1.3);
                    j.spin = time * (0.04 + 0.04 * hi) + fi * 1.9;
                    j.hue = hi;
                    j.glow = (0.75 + 0.5 * bass + 0.35 * drop + 0.15 * energy) * (1.0 + 1.5 * j.kick + 0.5 * snare);
                    jellies[i] = j;
                    depths[i] = dot(j.center - cam.ro, cam.fw);
                    order[i] = i;
                }
                for (int a = 0; a < kJellies - 1; a++) {
                    for (int b = 0; b < kJellies - 1 - a; b++) {
                        if (depths[order[b]] < depths[order[b + 1]]) {
                            int t = order[b];
                            order[b] = order[b + 1];
                            order[b + 1] = t;
                        }
                    }
                }
                for (int n = 0; n < kJellies; n++) {
                    int i = order[n];
                    JellyBody j = jellies[i];
                    float3 hueColor = paletteAt(u, j.hue);
                    float3 shellTint = mix(mix(u.c2.rgb, hueColor, 0.45), float3(0.85, 0.95, 1.0), 0.5);
                    float3 gonadTint = mix(mix(u.c1.rgb, hueColor, 0.3), float3(1.0, 0.75, 0.9), 0.25);
                    float3 tentTint = mix(mix(u.c0.rgb, u.c2.rgb, 0.5), float3(0.9, 0.9, 1.0), 0.4);
                    // Far jellies sink into the blue.
                    float fog = exp(-max(depths[i] - 2.6, 0.0) * 0.35);
                    JellyLayer layer = jellyDraw(
                        j, cam, sp, px, dither, shellTint * fog, gonadTint * fog, tentTint * fog, hat, highs, drop,
                        spectrum);
                    col = (col + layer.behind) * layer.transmit + layer.bell + layer.front;
                }

                col = fxFlash(col, u, 0.35);
                col = fxTonemap(col, 1.25);
                col = fxVignette(col, p, 0.12);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
