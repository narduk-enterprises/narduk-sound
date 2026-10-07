#if canImport(Metal)
    /// Bass blobs, appended to `ShaderPackSource`. Glossy liquid metaballs in a dark studio: five orbiting spheres
    /// and a core, soft-unioned, with a fresnel rim and a studio softbox in the reflection. Bass swells them and
    /// pulls them together, mids set the orbit speed, highs add a fine surface ripple, and the kick squashes the
    /// mass and lifts the rim. Calm (`fx.x`) slows every motion to 0.4 and removes the squash. The march is 48
    /// steps, the budget for 60 fps on an iPad.
    enum BassblobsShader {
        static let source = #"""
            struct BassField {
                float time;
                float motion;
                float bass;
                float mids;
                float highs;
                float kick;
            };

            static float bassSmin(float a, float b, float k) {
                float h = max(k - abs(a - b), 0.0) / k;
                return min(a, b) - h * h * k * 0.25;
            }

            static float bassMap(float3 p, BassField f) {
                float sy = max(1.0 - f.kick * 0.3, 0.66);
                float sx = 1.0 + f.kick * 0.18;
                float3 q = float3(p.x / sx, p.y / sy, p.z / sx);
                float tt = f.time * f.motion;
                q.y -= sin(tt * 0.37) * 0.05;
                // Merge only once the bass is strong, so a normal drop still shows kissing lobes.
                float merge = smoothstep(0.28, 1.0, f.bass);
                float spread = mix(0.78, 0.36, merge);
                float radius = mix(0.23, 0.38, f.bass);
                float blend = mix(0.18, 0.62, merge);
                float ang = tt * (0.26 + f.mids * 1.4);
                float coreR = 0.26 * merge;
                float d = coreR > 0.03 ? length(q) - coreR : 8.0;
                for (int i = 0; i < 5; i++) {
                    float fi = float(i);
                    float a = ang + fi * 1.2566371;
                    float y = 0.16 * sin(fi * 1.7) + 0.1 * sin(tt * 0.46 + fi);
                    float3 c = float3(cos(a) * spread, y, sin(a) * spread * 0.78);
                    float r = radius * (0.84 + 0.16 * sin(fi * 2.4 + 0.5));
                    d = bassSmin(d, length(q - c) - r, blend);
                }
                float rip = sin(q.x * 22.0 + q.z * 18.0 + tt * 1.5);
                rip *= sin(q.y * 20.0 - tt * 1.1);
                return d * sy + rip * f.highs * 0.012;
            }

            static float bassMarch(float3 ro, float3 rd, BassField f) {
                float t = 0.0;
                float d = 1.0;
                for (int i = 0; i < 44; i++) {
                    d = bassMap(ro + rd * t, f);
                    if (d < 0.0015) { return t; }
                    // The ripple's slope is above 1, so a full distance step tunnels.
                    t += max(d * 0.55, 0.002);
                    if (t > 7.0) { return -1.0; }
                }
                if (d > 0.08) { return -1.0; }
                float lo = max(t - 0.08, 0.0);
                float hi = t;
                for (int i = 0; i < 4; i++) {
                    float mid = 0.5 * (lo + hi);
                    if (bassMap(ro + rd * mid, f) < 0.0) { hi = mid; }
                    else { lo = mid; }
                }
                return hi;
            }

            static float3 bassNormal(float3 p, BassField f) {
                float e = 0.0022;
                float3 n = float3(
                    bassMap(p + float3(e, 0.0, 0.0), f) - bassMap(p - float3(e, 0.0, 0.0), f),
                    bassMap(p + float3(0.0, e, 0.0), f) - bassMap(p - float3(0.0, e, 0.0), f),
                    bassMap(p + float3(0.0, 0.0, e), f) - bassMap(p - float3(0.0, 0.0, e), f));
                return normalize(n);
            }

            // How hard the reflection ray hits the softbox. Neutrals are the lamp.
            static float bassLamp(float3 r) {
                float2 pane = r.xz / max(r.y, 0.05) - float2(-0.28, 0.12);
                float box = smoothstep(0.72, 0.05, length(pane * float2(0.75, 1.35)));
                return box * smoothstep(0.0, 0.22, r.y);
            }

            // Dark room plus one softbox. c2 is the room; c0 is a little floor bounce.
            static float3 bassStudio(float3 r, float3 c2, float3 c0) {
                float up = saturate(r.y * 0.5 + 0.5);
                float3 col = mix(c2 * 0.04, c2 * 0.2, up);
                col += float3(0.92, 0.95, 0.98) * bassLamp(r) * 0.85;
                col += c0 * saturate(-r.y) * 0.1;
                return col;
            }

            static float3 bassBackdrop(float2 uv, float aspect, float3 c2) {
                // uv.y is 0 at the top. Dark ceiling, a little of c2 toward the floor.
                float down = smoothstep(0.05, 0.85, uv.y);
                float3 col = mix(c2 * 0.012, c2 * 0.07, down);
                float2 p = (uv - 0.5) * float2(aspect, 1.0);
                float vig = smoothstep(1.15, 0.2, length(p));
                return col * (0.55 + 0.45 * vig);
            }

            // MARK: Bass blobs

            fragment float4 bassBlobsFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = saturate(u.fx.x);
                float bass = 0.0;
                for (int i = 0; i < 10; i++) { bass += spectrum[i]; }
                bass /= 10.0;
                float mids = 0.0;
                for (int i = 10; i < 36; i++) { mids += spectrum[i]; }
                mids /= 26.0;
                float highs = 0.0;
                for (int i = 36; i < 64; i++) { highs += spectrum[i]; }
                highs /= 28.0;

                BassField field;
                field.time = u.resTime.z;
                field.motion = mix(1.0, 0.4, calm);
                field.bass = saturate(bass);
                field.mids = saturate(mids);
                field.highs = saturate(highs);
                field.kick = saturate(u.env.x) * (1.0 - calm);

                float3 ro = float3(0.08, 0.72, 3.55);
                float3 ww = normalize(float3(0.0, 0.05, 0.0) - ro);
                float3 uu = normalize(cross(ww, float3(0.0, 1.0, 0.0)));
                float3 vv = cross(uu, ww);
                // uv.y is 0 at the top of the frame; screen-up has to be world-up.
                float2 q = (in.uv - 0.5) * float2(aspect, 1.0);
                q.y = -q.y;
                float3 rd = normalize(uu * q.x + vv * q.y + ww * 1.75);

                float3 bg = bassBackdrop(in.uv, aspect, u.c2.rgb);
                float floorY = -1.45;
                float floorT = 1e4;
                if (rd.y < -0.001) { floorT = (floorY - ro.y) / rd.y; }
                float tHit = bassMarch(ro, rd, field);
                float3 col = bg;
                if (tHit > 0.0 && tHit < floorT) {
                    float3 p = ro + rd * tHit;
                    float3 n = bassNormal(p, field);
                    float3 view = -rd;
                    float ndv = saturate(dot(n, view));
                    float fres = pow(1.0 - ndv, 2.5);
                    float3 keyL = normalize(float3(-0.3, 0.78, 0.55));
                    float diff = saturate(dot(n, keyL));
                    float3 fillL = normalize(float3(0.6, 0.05, 0.25));
                    float fill = saturate(dot(n, fillL));
                    float3 halfL = normalize(keyL + view);
                    float spec = pow(saturate(dot(n, halfL)), 70.0);
                    float3 albedo = u.c0.rgb;
                    float3 reflDir = reflect(-view, n);
                    float3 refl = bassStudio(reflDir, u.c2.rgb, albedo);
                    col = albedo * (0.08 + diff * 0.72 + fill * 0.14);
                    col = mix(col, refl, 0.08 + 0.62 * fres);
                    col += float3(0.95, 0.97, 1.0) * bassLamp(reflDir) * (0.35 + 0.15 * fres);
                    col += u.c1.rgb * fres * (0.55 + field.kick * 0.6);
                    col += float3(0.96, 0.97, 0.99) * spec * 0.28;
                    float ao = saturate(bassMap(p + n * 0.12, field) / 0.12);
                    col *= 0.42 + 0.58 * ao;
                } else if (floorT < 20.0) {
                    float3 fp = ro + rd * floorT;
                    float dist2 = dot(fp.xz, fp.xz);
                    float pool = exp(-dist2 * 0.35);
                    col = u.c2.rgb * (0.18 + 0.28 * pool);
                    float shadow = exp(-dist2 * mix(1.6, 0.7, field.bass));
                    col *= mix(1.0, 0.45, shadow * 0.85);
                    float3 fr = reflect(rd, float3(0.0, 1.0, 0.0));
                    col = mix(col, bassStudio(fr, u.c2.rgb, u.c0.rgb), 0.22);
                    // Grazing rays stay with the sky so the horizon is not a hard line.
                    float settle = saturate(-rd.y * 2.4) * saturate(exp(-floorT * 0.04));
                    col = mix(bg, col, settle);
                }
                col = 1.0 - exp(-col * 1.25);
                col += (hash21(floor(in.position.xy)) - 0.5) / 255.0;
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
