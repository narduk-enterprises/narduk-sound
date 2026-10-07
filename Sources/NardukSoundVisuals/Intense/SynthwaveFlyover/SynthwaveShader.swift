#if canImport(Metal)
    /// Synthwave flyover: a heightfield of neon grid ridged by the spectrum (low bands near the road, high bands
    /// out at the edges), a striped sun on the horizon, stars, fog. The drop lifts the camera off the road.
    enum SynthwaveShader {
        static let source = #"""
            static float terrain(constant float *spectrum, float2 xz, float amp) {
                float ax = abs(xz.x);
                float side = smoothstep(2.2, 4.8, ax);
                float band = bandAt(spectrum, clamp((ax - 2.2) / 16.0, 0.0, 1.0));
                float swell = 0.55 + 0.45 * sin(xz.y * 0.31 + ax * 0.6);
                return side * (0.5 + 3.4 * band * amp) * swell;
            }

            static float3 waveFinish(float3 col, float2 q) {
                col *= 1.0 - 0.07 * dot(q, q);
                col = 1.0 - exp(-col * 1.35);
                return pow(col, float3(0.92));
            }

            fragment float4 synthwaveFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float4 *motion [[buffer(3)]]) {
                float2 res = u.resTime.xy;
                float2 q = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
                q.x *= res.x / res.y;
                float t = u.resTime.z;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float flash = u.extra.x;
                float travel = motion[1].x;
                float lift = motion[1].y;
                float amp = motion[1].z;

                float3 ro = float3(0.0, 1.4 + lift * 4.5, 0.0);
                float pitch = lift * 0.10 - 0.02;
                float3 rd = normalize(float3(q.x, q.y + pitch * 1.6, 1.6));

                float tinted = u.extra.y;
                float3 horizon = mix(u.c1.rgb, mix(float3(1.0, 0.25, 0.65), u.c2.rgb, tinted), 0.5) * 0.8;
                float3 zenith = float3(0.03, 0.01, 0.10) + u.c0.rgb * 0.06;
                float3 col;
                float tHit = -1.0;
                float3 hitPos = float3(0.0);
                float tt = 0.4;
                for (int i = 0; i < 80; i++) {
                    float3 p = ro + rd * tt;
                    float h = terrain(spectrum, float2(p.x, p.z + travel), amp);
                    float gap = p.y - h;
                    if (gap < 0.0) {
                        float lo = tt - max(0.04 * tt + 0.05, 0.3 * 0.5), hi = tt;
                        for (int j = 0; j < 4; j++) {
                            float mid = 0.5 * (lo + hi);
                            float3 pm = ro + rd * mid;
                            if (pm.y < terrain(spectrum, float2(pm.x, pm.z + travel), amp)) { hi = mid; } else { lo = mid; }
                        }
                        tHit = hi;
                        hitPos = ro + rd * hi;
                        break;
                    }
                    tt += max(0.04 * tt + 0.05, gap * 0.4);
                    if (tt > 90.0) { break; }
                }

                if (tHit > 0.0) {
                    float z = hitPos.z + travel;
                    float h = terrain(spectrum, float2(hitPos.x, z), amp);
                    float w = 0.02 + tHit * 0.0045;
                    float2 d = 0.5 - abs(fract(float2(hitPos.x, z) * 0.5) - 0.5);
                    float lines = 1.0 - smoothstep(0.0, w, min(d.x, d.y));
                    float pulse = 0.55 + 0.45 * sin(z * 0.7 - beats * 6.2831853);
                    float3 neon = mix(u.c1.rgb, u.c2.rgb, saturate(h * 0.35));
                    col = u.c0.rgb * 0.12 + neon * lines * (0.9 + 0.9 * pulse + 1.4 * kick);
                    col += neon * 0.08 * saturate(h * 0.5);
                    float fog = 1.0 - exp(-tHit * 0.034);
                    col = mix(col, horizon * 0.55, fog);
                } else {
                    float up = rd.y / rd.z;
                    float sx = rd.x / rd.z;
                    float sky = saturate(up * 2.2 + 0.1);
                    col = mix(horizon, zenith, sqrt(sky));
                    float2 sc = float2(sx, up - (0.06 + pitch * 0.0));
                    float R = 0.42 * (1.0 + 0.06 * kick);
                    float dist = length(sc - float2(0.0, 0.18));
                    float sunMask = 1.0 - smoothstep(R - 0.01, R, dist);
                    float sy = saturate((0.18 + R - sc.y) / (2.0 * R));
                    float bars = step(sy * 0.65, fract(sy * 9.0 - t * 0.15));
                    float cut = sy > 0.35 ? bars : 1.0;
                    float3 sun = mix(mix(float3(1.0, 0.82, 0.30), mix(u.c2.rgb, float3(1.0), 0.4), tinted), u.c1.rgb * 1.2, smoothstep(0.1, 0.9, sy));
                    col = mix(col, sun, sunMask * cut);
                    col += mix(u.c1.rgb, u.c2.rgb, 0.4) * exp(-max(dist - R, 0.0) * 4.0) * (0.35 + 0.35 * kick);
                    float2 cell = floor(float2(sx, up) * 38.0);
                    float star = step(0.985, hash21(cell)) * smoothstep(0.05, 0.4, up);
                    col += star * (0.5 + 0.5 * sin(t * 2.0 + hash21(cell + 7.0) * 6.28)) * 0.8;
                }
                col += u.flashColor.rgb * flash * 0.55;
                return float4(waveFinish(col, q), 1.0);
            }
            """#
    }
#endif
