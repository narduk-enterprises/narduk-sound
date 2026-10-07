#if canImport(Metal)
    /// Fractal dive: a Mandelbrot zoom toward a boundary point. Depth, target and turn come from `IntenseDrive`;
    /// the kick pushes the zoom (on the CPU), the spectrum brightens the bands, orbit-trap glow fills the inside.
    enum FractalDiveShader {
        static let source = #"""
            static float3 diveFinish(float3 col, float2 q) {
                col *= 1.0 - 0.07 * dot(q, q);
                col = 1.0 - exp(-col * 1.1);
                float luma = dot(col, float3(0.299, 0.587, 0.114));
                col = max(mix(float3(luma), col, 1.7), 0.0);
                return pow(col, float3(1.5));
            }

            fragment float4 fractalDiveFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float4 *motion [[buffer(3)]]) {
                float2 res = u.resTime.xy;
                float2 q = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
                q.x *= res.x / res.y;
                float t = u.resTime.z;
                float kick = u.env.x;
                float energy = u.wobble.z;
                float flash = u.extra.x;
                float depth = motion[0].x;
                float2 target = motion[0].yz;
                float turn = motion[0].w;
                float hue = motion[1].w;

                float ca = cos(turn), sa = sin(turn);
                float2 r = float2(q.x * ca - q.y * sa, q.x * sa + q.y * ca);
                float scale = 1.6 * exp(-depth);
                float k = 1.0 - exp(-depth * 1.5);
                float2 center = mix(float2(-0.5, 0.0), target, k);
                float2 c = center + r * scale;

                float2 z = float2(0.0);
                float2 dz = float2(0.0);
                float trap = 1e9;
                float trapRing = 1e9;
                float n = 0.0;
                bool escaped = false;
                int maxIt = int(mix(90.0, 230.0, saturate(depth / 7.0)));
                for (int i = 0; i < maxIt; i++) {
                    dz = 2.0 * float2(z.x * dz.x - z.y * dz.y, z.x * dz.y + z.y * dz.x) + float2(1.0, 0.0);
                    z = float2(z.x * z.x - z.y * z.y, 2.0 * z.x * z.y) + c;
                    float m = dot(z, z);
                    trap = min(trap, abs(z.x * z.y) + 0.02 * m);
                    trapRing = min(trapRing, abs(sqrt(m) - 0.65));
                    if (m > 256.0) { escaped = true; break; }
                    n += 1.0;
                }

                float3 col;
                float pixel = 2.0 * scale / res.y;
                if (escaped) {
                    float sl = n - log2(log2(dot(z, z))) + 4.0;
                    float band = bandAt(spectrum, fract(sl * 0.015));
                    float tone = sl * 0.03 + hue + t * 0.02 + energy * 0.1;
                    float mz = length(z);
                    float de = 0.5 * mz * log(mz) / max(length(dz), 1e-20);
                    float edge = 1.0 / (1.0 + 0.1 * de / pixel);
                    float rings = pow(0.5 + 0.5 * sin(sl * 1.1 - t * (1.0 + 3.0 * kick)), 4.0);
                    float3 base = paletteAt(u, tone);
                    col = base * (0.02 + 0.45 * rings * (0.6 + band)) * edge * 2.2;
                    col += paletteAt(u, tone + 0.4) * pow(edge, 1.6) * (1.1 + 1.4 * kick + 0.8 * band);
                } else {
                    float g = exp(-trap * 40.0);
                    float3 inner = paletteAt(u, hue + trap * 3.0 + t * 0.03);
                    col = inner * g * (0.5 + 1.1 * kick + 0.5 * energy);
                    col += paletteAt(u, hue + 0.5) * exp(-trapRing * 22.0) * (0.35 + 0.5 * kick);
                }
                col += u.flashColor.rgb * flash * 0.6;
                return float4(diveFinish(col, q), 1.0);
            }
            """#
    }
#endif
