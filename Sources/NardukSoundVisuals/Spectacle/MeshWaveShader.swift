#if canImport(Metal)
    /// Mesh wave: a luminous square grid draped on a finite heightfield sheet. Appended to `ShaderPackSource` so it
    /// shares `PackUniforms` and `bandAt`. Bass lifts the two swells and deepens the trough, mids roll a travelling
    /// wave, highs ripple the grid, a kick sends a bounded ring and a line glow, and `fx.x` (calm) slows motion to
    /// 0.4 and removes the kick.
    enum MeshWaveShader {
        static let fragment = #"""

            // MARK: Mesh wave

            static float meshKickEnvelope(float2 xz, float kick) {
                float d = length(xz - float2(0.0, 3.1));
                float radius = 0.4 + (1.0 - kick) * 3.6;
                float radial = d - radius;
                return exp(-(radial * radial) * 2.4) * kick;
            }

            static float meshHeight(float2 xz, float bass, float mids, float highs, float drop, float kick,
                float travel, float time) {
                float k = 1.38 + drop * 0.24;
                float arg = xz.x * k - 1.58 + travel * 0.12 + time * 0.03;
                float s = sin(arg);
                float amp = 0.64 + bass * 0.40 + drop * 0.22;
                float trough = s >= 0.0 ? 1.0 : (1.2 + bass * 0.45 + drop * 0.24);
                float h = s * amp * trough;
                h *= 0.9 + 0.1 * cos(xz.y * 0.36);
                float scroll = travel * 0.9 + time * 0.4;
                h += sin(xz.x * 1.65 - scroll + xz.y * 0.45) * (0.04 + mids * 0.26);
                h += sin(xz.x * 8.0 + xz.y * 7.0 + time * 1.6) * highs * 0.03;
                float d = length(xz - float2(0.0, 3.1));
                h += sin(d * 6.2 - time * 2.2) * meshKickEnvelope(xz, kick) * 0.36;
                return h;
            }

            fragment float4 meshWaveFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float calm = saturate(u.fx.x);
                float motion = 1.0 - 0.6 * calm;
                float bass = bandAt(spectrum, 0.05);
                float mids = bandAt(spectrum, 0.40);
                float highs = bandAt(spectrum, 0.80);
                float drop = saturate(u.misc.y);
                float kick = u.env.x * (1.0 - calm);
                float travel = u.misc.z * motion;
                float time = u.resTime.z * motion;
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float2 q = (in.uv - 0.5) * float2(aspect, 1.0);
                q.y = -q.y;

                float3 ro = float3(0.0, 1.7, -2.15);
                float3 ta = float3(0.0, 0.32, 3.35);
                float3 ww = normalize(ta - ro);
                float3 uu = normalize(cross(ww, float3(0.0, 1.0, 0.0)));
                float3 vv = cross(uu, ww);
                float3 rd = normalize(uu * q.x + vv * q.y + ww * 2.05);

                float z0 = 1.55;
                float z1 = 5.45;
                float t0 = 0.05;
                float t1 = 22.0;
                if (rd.z > 0.02) {
                    float a = (z0 - ro.z) / rd.z;
                    float b = (z1 - ro.z) / rd.z;
                    t0 = max(min(a, b), 0.05);
                    t1 = min(max(a, b), 22.0);
                }

                float hitT = -1.0;
                float t = t0;
                float prev = t0;
                for (int i = 0; i < 40; i++) {
                    if (t > t1) { break; }
                    float3 p = ro + rd * t;
                    float gap = p.y - meshHeight(p.xz, bass, mids, highs, drop, kick, travel, time);
                    if (gap < 0.0015) {
                        float lo = prev;
                        float hi = t;
                        for (int j = 0; j < 8; j++) {
                            float mid = 0.5 * (lo + hi);
                            float3 pm = ro + rd * mid;
                            float g = pm.y - meshHeight(pm.xz, bass, mids, highs, drop, kick, travel, time);
                            if (g < 0.0) { hi = mid; } else { lo = mid; }
                        }
                        hitT = hi;
                        break;
                    }
                    prev = t;
                    t += clamp(gap * 0.58, 0.015, 0.32);
                    if (t > t1) { break; }
                }

                float3 col = float3(0.0);
                if (hitT > 0.0) {
                    float3 hit = ro + rd * hitT;
                    float e = 0.08;
                    float h0 = meshHeight(hit.xz, bass, mids, highs, drop, kick, travel, time);
                    float hx = meshHeight(hit.xz + float2(e, 0.0), bass, mids, highs, drop, kick, travel, time);
                    float hz = meshHeight(hit.xz + float2(0.0, e), bass, mids, highs, drop, kick, travel, time);
                    float3 n = normalize(float3(-(hx - h0) / e, 1.0, -(hz - h0) / e));
                    float3 lightDir = normalize(float3(-0.2, 0.86, -0.25));
                    float diff = 0.42 + 0.58 * saturate(dot(n, lightDir));
                    float3 viewDir = normalize(ro - hit);
                    float spec = pow(saturate(dot(reflect(-lightDir, n), viewDir)), 30.0);
                    float fres = pow(1.0 - saturate(dot(n, -rd)), 2.6);

                    float2 gv = hit.xz;
                    gv.x += sin(hit.z * 16.0 + time * 2.4) * highs * 0.045;
                    gv.y += sin(hit.x * 16.0 - time * 2.0) * highs * 0.045;
                    gv *= 7.1;
                    // The grid's pixel footprint, from the ray's spread at the hit (one pixel is 1/height of q,
                    // and the ray divides q by 2.05), stretched where the mesh is seen edge-on. Not fwidth: a
                    // derivative inside this per-pixel branch is undefined and drew different pixels per run on
                    // a virtual GPU (CI's macOS runner).
                    float footprint = 7.1 * hitT / (2.05 * max(u.resTime.y, 1.0));
                    float2 fw = float2(max(footprint / max(abs(dot(n, rd)), 0.15), 1e-3));
                    float2 cell = min(fract(gv), 1.0 - fract(gv));
                    float line = min(cell.x / fw.x, cell.y / fw.y);
                    float core = exp(-line * line * 1.45);
                    float halo = exp(-line * line * 0.11) * 0.46;
                    float bloom = exp(-line * line * 0.03) * 0.16;

                    float side = smoothstep(0.6, -3.1, hit.x);
                    float3 tint = mix(u.c0.rgb, u.c1.rgb, side);
                    float3 hot = mix(u.c2.rgb, float3(0.78, 0.92, 1.0), 0.5);
                    float3 tube = mix(tint, hot, saturate(core * 0.8));
                    float glow = meshKickEnvelope(hit.xz, kick);
                    float gain = 0.95 + drop * 0.7 + kick * 0.22;
                    col = tube * (core * 1.55 + halo + bloom) * diff;
                    col += hot * core * (spec * 1.05 + fres * 0.95);
                    col += tint * (core * 0.9 + halo) * glow * 1.2;
                    col += hot * core * kick * 0.18;

                    float fade = smoothstep(z0, z0 + 0.7, hit.z);
                    fade *= smoothstep(z1, z1 - 0.85, hit.z);
                    fade *= exp(-hit.x * hit.x * 0.055);
                    fade *= smoothstep(0.0, 0.05, in.uv.y) * smoothstep(1.0, 0.74, in.uv.y);
                    fade *= smoothstep(0.0, 0.05, in.uv.x) * smoothstep(1.0, 0.95, in.uv.x);
                    col *= gain * fade;
                    col = 1.0 - exp(-col * 1.45);
                }
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
