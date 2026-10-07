#if canImport(Metal)
    /// Aurora curtains: vertical sheets of domain-warped fbm over a night sky.
    ///
    /// Bass lengthens and brightens the sheets, mids fold them, highs hang fine rays from the hem, and the kick
    /// lights only that hem. `fx.x` is the calm flag: drift drops to 0.4 and the hem glow goes away. c0 is the
    /// sheet, c1 the fringe, c2 the upper sky. Nothing here strobes.
    enum AuroraCurtainsShader {
        static let source = #"""

            static float valueNoise(float2 p) {
                float2 i = floor(p);
                float2 f = fract(p);
                f = f * f * (3.0 - 2.0 * f);
                float a = hash21(i);
                float b = hash21(i + float2(1.0, 0.0));
                float c = hash21(i + float2(0.0, 1.0));
                float d = hash21(i + float2(1.0, 1.0));
                return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
            }

            static float fbm(float2 p) {
                float v = 0.0;
                float a = 0.5;
                float2x2 rot = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
                for (int i = 0; i < 4; i++) {
                    v += a * valueNoise(p);
                    p = rot * p * 2.05 + float2(1.7, 9.2);
                    a *= 0.5;
                }
                return v;
            }

            fragment float4 auroraFragment(
                PackVertexOut in [[stage_in]], constant PackUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]
            ) {
                float aspect = u.resTime.x / max(u.resTime.y, 1.0);
                float calm = saturate(u.fx.x);
                float motion = mix(1.0, 0.4, calm);
                float t = u.resTime.z;
                float drift = (t * 0.045 + u.resTime.w * 0.012 + u.misc.z * 0.003) * motion;

                float bass = bandAt(spectrum, 0.02) + bandAt(spectrum, 0.08) + bandAt(spectrum, 0.12);
                bass /= 3.0;
                float mids = (bandAt(spectrum, 0.22) + bandAt(spectrum, 0.38)) * 0.5;
                float highs = (bandAt(spectrum, 0.60) + bandAt(spectrum, 0.82)) * 0.5;

                float yUp = 1.0 - in.uv.y;
                float x = in.uv.x;

                float3 color = float3(0.008, 0.009, 0.014);
                float skyGlow = exp(-pow((yUp - 0.84) * 2.2, 2.0));
                color += u.c2.rgb * skyGlow * (0.40 + 0.12 * u.wobble.z);
                color += u.c2.rgb * smoothstep(0.45, 1.0, yUp) * 0.06;

                float2 gv = float2(x * max(aspect, 0.8) * 11.0, yUp * 8.0);
                float2 id = floor(gv);
                float2 f = fract(gv) - 0.5;
                float h = hash21(id + float2(2.0, 5.0));
                float show = step(0.78, h);
                float2 jitter = float2(hash21(id + 3.7), hash21(id + 8.2)) - 0.5;
                float2 q = f - jitter * 0.35;
                float star = smoothstep(0.055, 0.0, length(q)) * show;
                float twinkle = 0.45 + 0.55 * sin(t * (0.28 + h * 0.7) * motion + h * 28.0);
                float starSky = smoothstep(0.02, 0.22, yUp);

                float travelX = x + drift * 0.20;
                float columns = 4.0;
                float col = floor(travelX * columns);
                float local = fract(travelX * columns) - 0.5;
                float hcol = hash21(float2(col, 1.3));
                float2 np = float2(travelX * 3.6, yUp * 2.1);
                float n = fbm(np);
                float w = fbm(np + float2(n * (0.7 + mids * 2.4), 4.8));
                float silk = fbm(float2(travelX * 7.5 + 2.4, yUp * 3.6 + drift));
                float down = 0.25 + 0.75 * (1.0 - yUp);
                float bend = (w - 0.5) * (0.06 + 1.05 * mids) * down;
                bend += (silk - 0.5) * (0.015 + 0.22 * mids) * down;
                float shifted = local + bend;

                float hem = mix(0.58, 0.03, saturate(bass));
                hem += (fbm(float2(travelX * 3.4 + 1.1, 2.6)) - 0.5) * 0.18;
                float topFade = smoothstep(0.995, 0.66, yUp);
                float body = smoothstep(hem - 0.03, hem + 0.035, yUp) * topFade;
                float gas = 0.52 + 0.48 * silk;

                float halfW = 0.28 + hcol * 0.10;
                float ad = abs(shifted);
                float sheet = smoothstep(halfW, halfW * 0.32, ad);
                float spine = smoothstep(halfW * 0.28, 0.0, ad);
                float glow = smoothstep(halfW + 0.08, halfW * 0.5, ad);
                float backShift = fract(travelX * columns + 0.5) - 0.5 + bend * 0.45;
                float back = smoothstep(0.36, 0.08, abs(backShift)) * 0.22;

                float light = 0.46 + bass * 0.95 + u.wobble.z * 0.10;
                float fringeMix = 1.0 - smoothstep(hem + 0.01, hem + 0.16, yUp);
                float3 sheetCol = mix(u.c0.rgb, u.c1.rgb, fringeMix * 0.75);
                float3 curtain = sheetCol * (sheet * 0.70 + glow * 0.20) * gas * light;
                curtain += u.c0.rgb * spine * gas * (0.16 + bass * 0.28);
                curtain += mix(u.c0.rgb, u.c2.rgb, 0.7) * back * gas * light;

                float hemLine = exp(-pow((yUp - (hem + 0.02)) / 0.016, 2.0)) * sheet;
                float rayFreq = mix(8.0, 20.0, saturate(highs));
                float ray = pow(saturate(1.0 - abs(sin(shifted * rayFreq + silk * 6.0))), 2.6);
                float rim = hem + 0.02;
                float dangle = exp(-max(rim - yUp, 0.0) * (12.0 + highs * 16.0));
                dangle *= smoothstep(rim + 0.05, rim - 0.03, yUp);
                float shimmer = 0.48 + 0.52 * sin(t * 1.15 * motion + col * 1.7 + silk * 7.0);
                float rays = ray * dangle * shimmer * saturate((highs - 0.02) * 3.6) * sheet;

                float beat = u.env.x * (1.0 - calm);
                float edgeGlow = min(hemLine * beat, 0.55);

                color += curtain * body;
                color += u.c1.rgb * hemLine * body * 0.28;
                color += mix(u.c0.rgb, u.c1.rgb, 0.35) * rays * 1.25;
                color += u.c1.rgb * edgeGlow * 0.40;

                float cover = saturate(spine * body * 1.5 + hemLine);
                float starVis = starSky * (1.0 - cover);
                color += float3(0.90, 0.93, 0.98) * star * twinkle * starVis * (0.8 + highs * 0.2);

                float2 vig = in.uv * 2.0 - 1.0;
                color *= 1.0 - dot(vig * float2(0.7, 1.0), vig) * 0.08;
                color = min(color, float3(0.88));
                return float4(color, 1.0);
            }
            """#
    }
#endif
