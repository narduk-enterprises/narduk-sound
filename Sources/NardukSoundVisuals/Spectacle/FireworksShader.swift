#if canImport(Metal)
    /// Fireworks over a dark night sky. The picture is a pure function of the pack uniforms, so a frame is
    /// deterministic and the GPU allocates nothing.
    ///
    /// Bass and the kick launch shells and set how big they break. Mids pick the shell (peony, chrysanthemum,
    /// willow, ring, crossette) and slide its colour along c0, c1, c2, with white-gold mixed in. Highs twinkle the
    /// heads. Snare and hat crackle, locally. A drop fires a short finale volley; calm keeps a few slow soft shells
    /// and no volley. Nothing here is a full-screen flash: light is added per spark and tone-mapped.
    enum FireworksShader {
        static let source = #"""

            // MARK: Fireworks

            struct FwIn {
                float bass;
                float mids;
                float highs;
                float kick;
                float snare;
                float hat;
                float energy;
                float dropAmt;
                float calm;
                float motion;
                float time;
                float beats;
                float barPhase;
                float aspect;
                float px;
                float level;
                float crackle;
                float volley;
                float presence;
                float beatPulse;
            };

            static float fwSkyline(float x) {
                float zone = hash21(float2(floor(x * 1.6 + 5.0), 8.0));
                float buildings = 0.0;
                if (zone > 0.36) {
                    float cell = floor(x * 7.5 + 6.0);
                    float n = hash21(float2(cell, 2.0));
                    buildings = 0.010 + n * n * 0.125;
                    buildings += step(0.8, n) * 0.05;
                }
                float treeCell = floor(x * 21.0 + 1.0);
                float tn = hash21(float2(treeCell, 5.0));
                float trees = step(0.42, tn) * (0.018 + 0.05 * tn * tn);
                return max(buildings, trees);
            }

            static float2 fwPos(float2 origin, float2 dir, float speed, float drag, float grav, float t) {
                float integ = (1.0 - exp(-drag * max(t, 0.0))) / max(drag, 0.15);
                return origin + dir * speed * integ + float2(0.0, -0.5 * grav * t * t);
            }

            static float3 fwSpark(
                float2 w, float2 head, float2 tail, float3 tint, float3 hot, float amp, float flicker, float px,
                float trailAmt
            ) {
                float2 span = head - tail;
                float denom = max(dot(span, span), 1e-6);
                float along = clamp(dot(w - tail, span) / denom, 0.0, 1.0);
                float seg = length(w - (tail + span * along));
                float trailW = max(px * 2.5, 0.0034);
                float trail = exp(-(seg * seg) / (trailW * trailW)) * along * trailAmt;
                float2 delta = w - head;
                float d2 = dot(delta, delta);
                float coreW = max(px * 1.15, 0.0018);
                float haloW = max(px * 4.8, 0.006);
                float core = exp(-d2 / (coreW * coreW));
                float halo = exp(-d2 / (haloW * haloW));
                return (hot * core * 1.15 + tint * halo * 0.7 + tint * trail * 0.48) * amp * flicker;
            }

            static float3 fwShow(float2 w, FwIn a, constant PackUniforms &u, float soft) {
                float3 sky = mix(float3(0.010, 0.012, 0.034), float3(0.002, 0.003, 0.010), smoothstep(0.0, 0.72, w.y));
                sky += float3(0.055, 0.028, 0.016) * exp(-max(w.y, 0.0) * 7.5) * 0.55;
                float grain = hash21(floor(w * float2(22.0, 16.0) + 3.0));
                sky += float3(0.008, 0.010, 0.016) * grain * grain;

                float2 starCell = floor(w * float2(130.0, 96.0));
                float sh = hash21(starCell + 19.0);
                float star = step(0.992, sh);
                float2 starAt = (starCell + 0.5 + (hash21(starCell) - 0.5) * 0.7) / float2(130.0, 96.0);
                float tw = 0.62 + 0.38 * sin(a.time * (1.1 + sh * 3.4) + sh * 40.0);
                tw *= 0.7 + 0.55 * a.highs;
                float sd = length(w - starAt);
                float starW = max(a.px * 1.15, 0.0018);
                sky += float3(0.78, 0.84, 1.0) * star * exp(-(sd * sd) / (starW * starW)) * tw
                    * (soft > 0.5 ? 0.25 : 0.7);

                if (w.y < -0.02) return sky;

                float3 color = sky;
                float sim = a.time * a.motion;
                float drive = clamp(a.energy, 0.0, 1.0);
                float every = mix(0.88, 0.28, drive);
                if (a.calm > 0.5) every = max(every * 2.5, 1.45);
                int shells = a.calm > 0.5 ? 3 : 7;
                int total = shells;
                if (a.volley > 0.06 && a.calm < 0.5) total += 4;
                float slot = floor(sim / every);

                for (int i = 0; i < 12; i++) {
                    if (i >= total) break;
                    bool finale = i >= shells;
                    float id = finale ? floor(sim / (every * 4.0)) * 17.0 + float(i) : slot - float(i);
                    float launchT = finale
                        ? floor(sim / (every * 4.0)) * every * 4.0 + float(i - shells) * 0.065
                        : id * every;
                    float age = sim - launchT;
                    float h1 = hash21(float2(id, 2.2));
                    float h2 = hash21(float2(id, 6.4));
                    float h3 = hash21(float2(id, 11.0));
                    float depth = finale ? 0.15 : h2;
                    if (i == 0) depth *= 0.2;
                    float size = (0.4 + 0.95 * a.bass) * (0.72 + 0.38 * a.level) * mix(1.0, 0.64, depth);
                    if (i == 0) size *= 1.0 + 0.7 * a.kick * (0.35 + 0.65 * a.bass);
                    size = clamp(size, 0.18, 1.85);

                    float kind = 0.0;
                    float roll = fract(h3 + a.mids * 0.42);
                    if (roll > 0.20) kind = 1.0;
                    if (roll > 0.46) kind = 2.0;
                    if (roll > 0.66) kind = 3.0;
                    if (roll > 0.84) kind = 4.0;
                    if (finale) kind = float(i - shells);

                    float hue = fract(h1 * 0.71 + id * 0.173 + a.mids * 0.31 + kind * 0.04);
                    float3 tint = paletteAt(u, hue);
                    float3 gold = float3(1.0, 0.84, 0.46);
                    float goldAmt = h1 > 0.92 ? 0.74 : 0.0;
                    if (kind > 1.5 && kind < 2.5) goldAmt = 0.88;
                    tint = mix(tint, gold, goldAmt);
                    float3 hot = mix(tint, float3(1.0, 0.98, 0.93), 0.3);

                    float riseT = (0.58 + 0.38 * h2) * mix(1.12, 0.78, a.bass);
                    if (finale) riseT *= 0.62;
                    float apex = (0.16 + 0.4 * h1) * (0.58 + 0.62 * a.bass) * mix(1.0, 0.8, depth);
                    if (i == 0) apex *= 0.82 + 0.48 * a.bass;
                    apex = clamp(apex, 0.12, 0.66);
                    float x = finale
                        ? (float(i - shells) - 1.5) * a.aspect * 0.2
                        : (fract(id * 0.618034 + 0.27) - 0.5) * a.aspect * 0.76 + (h1 - 0.5) * 0.06;
                    float wind = (h3 - 0.5) * 0.045;
                    float climb = clamp(age / max(riseT, 0.05), 0.0, 1.0);
                    float y = apex * (1.0 - (1.0 - climb) * (1.0 - climb));
                    float2 launch = float2(x, 0.0);
                    float2 head = float2(x + wind * climb, y);

                    float amp = (0.5 + 0.4 * a.level) * a.presence * mix(1.0, 0.4, a.calm) * mix(1.0, 0.62, depth);
                    if (i == 0) amp *= 0.72 + 0.65 * max(a.kick, a.beatPulse * 0.45);
                    if (finale) amp *= 0.75 * a.volley;
                    if (age < 0.0 || age > riseT + 2.7 || amp < 0.004) continue;

                    if (age < riseT) {
                        float2 span = head - launch;
                        float denom = max(dot(span, span), 1e-6);
                        float along = clamp(dot(w - launch, span) / denom, 0.0, 1.0);
                        float seg = length(w - (launch + span * along));
                        float trailW = max(a.px * 1.05, 0.0015);
                        float lit = smoothstep(0.9, 1.0, along);
                        float trail = exp(-(seg * seg) / (trailW * trailW)) * lit;
                        color += tint * trail * amp * 0.22;
                        float2 dh = w - head;
                        float coreW = max(a.px * 1.45, 0.0022);
                        color += hot * exp(-dot(dh, dh) / (coreW * coreW)) * amp * 2.1;
                        color += tint * exp(-dot(dh, dh) / (coreW * coreW * 5.0)) * amp * 0.7;
                        if (age < 0.12) {
                            float2 dm = w - launch;
                            float muzzle = exp(-age * 14.0) * (0.3 + 0.7 * a.kick);
                            color += hot * exp(-dot(dm, dm) / (coreW * coreW * 2.0)) * muzzle * amp * 0.8;
                        }
                        continue;
                    }

                    float t = age - riseT;
                    float life = exp(-max(t - 0.08, 0.0) * (kind > 1.5 && kind < 2.5 ? 0.38 : 0.62));
                    amp *= life;
                    float2 origin = float2(x + wind, apex);

                    float speed = 0.32;
                    float drag = 1.25;
                    float grav = 0.18;
                    float trailDt = 0.16;
                    float vary = 0.18;
                    if (kind < 0.5) {
                        speed = 0.34; drag = 1.35; grav = 0.16; trailDt = 0.14; vary = 0.14;
                    } else if (kind < 1.5) {
                        speed = 0.38; drag = 0.85; grav = 0.34; trailDt = 0.36; vary = 0.38;
                    } else if (kind < 2.5) {
                        speed = 0.22; drag = 0.7; grav = 1.05; trailDt = 0.4; vary = 0.22;
                    } else if (kind < 3.5) {
                        speed = 0.4; drag = 1.5; grav = 0.06; trailDt = 0.12; vary = 0.1;
                    } else {
                        speed = 0.3; drag = 1.4; grav = 0.2; trailDt = 0.18; vary = 0.18;
                    }
                    speed *= 0.58 + 0.72 * size;
                    if (soft > 0.5) trailDt *= 0.45;

                    float integ = (1.0 - exp(-drag * t)) / max(drag, 0.15);
                    float reach = speed * integ;
                    float2 rc = w - origin;
                    rc.y += 0.5 * grav * t * t * 0.35;
                    float bloom = exp(-dot(rc, rc) / (0.006 + reach * reach * 0.07));
                    bloom *= exp(-t * 0.55);
                    color += tint * bloom * 0.12 * amp;

                    float haze = exp(-dot(rc, rc) / (0.016 + t * 0.026));
                    haze *= exp(-t * 0.3) * (1.0 - soft);
                    color += mix(float3(0.2, 0.16, 0.24), tint, 0.72) * haze * haze * 0.1 * amp;

                    float shore = exp(-abs(w.y) * 16.0) * exp(-abs(w.x - origin.x) * 2.6);
                    color += tint * shore * amp * 0.38 * exp(-t * 0.35);

                    float bound = reach + 0.5 * grav * t * t + 0.05;
                    bool inBurst = abs(w.x - origin.x) < bound && w.y < origin.y + reach + 0.04
                        && w.y > origin.y - bound;
                    if (!inBurst) continue;

                    int count = 16 + int(floor(a.bass * 14.0 + a.level * 6.0));
                    if (kind > 0.5 && kind < 1.5) count += 8;
                    if (a.calm > 0.5) count = min(count, 12);
                    if (soft > 0.5) count = min(count, 16);
                    count = min(count, 36);

                    bool split = kind > 3.5 && t > 0.42 && soft < 0.5 && a.calm < 0.5;
                    for (int s = 0; s < 36; s++) {
                        if (s >= count) break;
                        float fs = float(s);
                        float hs = hash21(float2(fs + 0.2, id + 4.0));
                        float hs2 = hash21(float2(id + 2.0, fs + 8.0));
                        float theta = acos(clamp(hs2 * 2.0 - 1.0, -1.0, 1.0));
                        if (kind > 2.5 && kind < 3.5) theta = 1.57 + (hs2 - 0.5) * 0.5;
                        float phi = hs * 6.2831853;
                        float sp = speed * (1.0 - vary * 0.45 + vary * hs);
                        if (kind < 2.5 || kind > 3.5) sp *= (s % 2 == 0) ? 1.0 : 0.52;
                        float2 dir = float2(sin(theta) * cos(phi), cos(theta));
                        if (kind > 1.5 && kind < 2.5) dir.y = abs(dir.y) * 0.75 + 0.2;
                        float2 pos = fwPos(origin, dir, sp, drag, grav, t);
                        float tb = max(t * 0.42, t - trailDt);
                        float2 tail = fwPos(origin, dir, sp, drag, grav, tb);
                        float flick = 1.0 + a.highs * 0.55 * sin(a.time * (4.2 + hs * 7.0) + hs2 * 19.0);
                        float ember = sin(a.time * 16.0 + hs * 26.0);
                        flick *= 1.0 + a.crackle * 0.55 * ember;
                        flick *= 0.78 + 0.22 * exp(-max(t - (0.85 + hs), 0.0) * 2.2);
                        float front = 0.5 + 0.5 * saturate(0.5 + 0.5 * sin(theta) * sin(phi));
                        float3 sparkTint = mix(tint, paletteAt(u, hue + 0.08), 0.22 * hs);
                        color += fwSpark(
                            w, pos, tail, sparkTint, hot, amp * front, flick, a.px, soft > 0.5 ? 0.55 : 1.0);

                        if (split && (s % 5) == 0 && s < 20) {
                            float2 splitAt = fwPos(origin, dir, sp, drag, grav, 0.42);
                            float t2 = t - 0.42;
                            float fade = exp(-t2 * 1.7);
                            float2 sd = w - splitAt;
                            color += sparkTint * exp(-dot(sd, sd) / 0.0012) * amp * fade * 0.35;
                            for (int m = 0; m < 6; m++) {
                                float ma = (float(m) + hs) * 1.0471976;
                                float2 mdir = float2(cos(ma), sin(ma));
                                float2 mp = fwPos(splitAt, mdir, sp * 0.7, drag * 1.1, grav * 0.8, t2);
                                float2 mtail = fwPos(splitAt, mdir, sp * 0.7, drag * 1.1, grav * 0.8, max(t2 * 0.4, t2 - 0.12));
                                color += fwSpark(w, mp, mtail, sparkTint, hot, amp * fade * 0.9, 1.0, a.px, 0.7);
                            }
                        }

                        if (a.crackle > 0.12 && hs > 0.74) {
                            float2 pop = pos + float2(hs - 0.5, hs2 - 0.5) * 0.02;
                            float popW = max(a.px * 1.05, 0.0016);
                            float popA = a.crackle * exp(-max(t - 0.15, 0.0) * 1.6);
                            color += float3(1.0, 0.95, 0.86) * exp(-dot(w - pop, w - pop) / (popW * popW)) * popA * amp
                                * 0.5;
                        }
                    }

                }

                // A small break on the beat while the kick is hot. It opens and fades with the beat, so a held
                // kick still looks like a shell and never lights the whole frame.
                if (a.kick > 0.08 && a.calm < 0.5 && soft < 0.5 && a.presence > 0.15) {
                    float id = floor(a.beats + 0.001);
                    float hx = hash21(float2(id, 3.1));
                    float hy = hash21(float2(id, 8.4));
                    float2 centre = float2((hx - 0.5) * a.aspect * 0.62, 0.22 + hy * 0.32);
                    float phase = fract(a.beats);
                    float kt = phase * 0.62;
                    float fade = exp(-phase * 2.6) * a.kick * (0.45 + 0.75 * a.bass);
                    if (length(w - centre) < 0.28 + 0.16 * a.bass) {
                        float3 tint = paletteAt(u, hx + 0.12);
                        float3 hot = mix(tint, float3(1.0, 0.97, 0.9), 0.35);
                        float kSpeed = 0.2 * (0.65 + 0.7 * a.bass);
                        for (int s = 0; s < 16; s++) {
                            float hs = hash21(float2(float(s), id + 1.5));
                            float hs2 = hash21(float2(id, float(s) + 2.5));
                            float theta = acos(clamp(hs2 * 2.0 - 1.0, -1.0, 1.0));
                            float phi = hs * 6.2831853;
                            float2 dir = float2(sin(theta) * cos(phi), cos(theta));
                            float2 pos = fwPos(centre, dir, kSpeed, 1.3, 0.16, kt);
                            float2 tail = fwPos(centre, dir, kSpeed, 1.3, 0.16, max(kt * 0.45, kt - 0.1));
                            color += fwSpark(w, pos, tail, tint, hot, fade * 0.62, 1.0, a.px, 0.55);
                        }
                    }
                }
                return color;
            }

            fragment float4 fireworksFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = u.fx.x > 0.5 ? 1.0 : 0.0;
                FwIn a;
                a.bass = clamp(bandAt(spectrum, 0.05), 0.0, 1.0);
                a.mids = clamp(bandAt(spectrum, 0.40), 0.0, 1.0);
                a.highs = clamp(bandAt(spectrum, 0.80), 0.0, 1.0);
                a.kick = clamp(u.env.x, 0.0, 1.0);
                a.snare = clamp(u.env.y, 0.0, 1.0);
                a.hat = clamp(u.env.z, 0.0, 1.0);
                a.energy = clamp(u.wobble.z, 0.0, 1.0);
                a.dropAmt = clamp(u.misc.y, 0.0, 1.0);
                a.calm = calm;
                a.motion = mix(1.0, 0.4, calm);
                a.time = u.resTime.z;
                a.beats = u.resTime.w;
                a.barPhase = u.misc.w;
                a.aspect = aspect;
                a.px = 1.0 / max(u.resTime.y, 1.0);
                a.level = clamp(a.energy * 0.62 + a.bass * 0.38, 0.0, 1.0);
                a.crackle = (a.snare * 0.75 + a.hat * 0.35) * (1.0 - calm);
                a.volley = (1.0 - calm) * smoothstep(0.58, 0.92, a.dropAmt) * exp(-a.barPhase * 3.0);
                a.presence = smoothstep(0.035, 0.22, a.energy);
                a.beatPulse = exp(-fract(a.beats) * 5.0);

                float horizon = 0.8;
                float2 w = float2((in.uv.x - 0.5) * aspect, horizon - in.uv.y);
                float3 color;
                if (w.y >= 0.0) {
                    color = fwShow(w, a, u, 0.0);
                    float roof = fwSkyline(w.x);
                    if (w.y < roof) {
                        float3 building = float3(0.0);
                        float2 cell = floor(float2(w.x * 62.0, w.y * 120.0));
                        float hw = hash21(cell + 4.0);
                        if (hw > 0.945 && w.y > 0.012) {
                            building = float3(1.0, 0.76, 0.4) * (0.05 + 0.16 * a.energy)
                                * (0.55 + 0.45 * hash21(cell + 9.0));
                        }
                        float rim = exp(-abs(w.y - roof) * 80.0);
                        color = building + color * rim * 0.45;
                    }
                } else {
                    float waterSpan = 1.0 - horizon;
                    float depth = clamp(-w.y / waterSpan, 0.0, 1.0);
                    float wob = sin(w.x * 24.0 + a.time * 1.2 + depth * 5.0) * (0.003 + 0.012 * depth);
                    wob += waveAt(wave, in.uv.x) * 0.014 * depth;
                    float2 rw = float2(w.x + wob, depth * horizon * 0.94);
                    float3 reflected = fwShow(rw, a, u, 1.0);
                    reflected *= float3(0.72, 0.8, 0.9);
                    float fade = (1.0 - 0.5 * depth) * 0.74;
                    color = float3(0.003, 0.006, 0.014) + reflected * fade;
                    float ripple = pow(0.5 + 0.5 * sin(w.x * 36.0 - a.time * 1.15 + depth * 8.0), 12.0);
                    color += reflected * ripple * 0.08;
                }

                float shore = exp(-w.y * w.y * 900.0);
                color += float3(0.55, 0.36, 0.18) * shore * (0.08 + 0.12 * a.presence);

                color = 1.0 - exp(-color * 1.05);
                float2 vig = (in.uv - 0.5) * float2(aspect, 1.0);
                color *= mix(0.78, 1.0, smoothstep(1.05, 0.25, length(vig)));
                return float4(clamp(color, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
