#if canImport(Metal)
    /// Fluid + glitch: GPU ink and smoke, advected each frame through a curl-noise flow with kick-driven injections
    /// (`fluidFragment`, which reads last frame's texture), then presented through the glitch pass
    /// (`glitchFragment`): RGB split, row tearing, block shifts and a pixel-sort style smear that grow on the drop.
    /// The glitch moves small regions and quantises to 8 Hz; the only full-screen flash is the rationed `extra.x`.
    enum FluidGlitchShader {
        static let source = #"""
            // Where the kick injects ink: a new place each beat.
            static float2 injectionPoint(float beats, float aspect) {
                float b = floor(beats);
                return float2((hash11(b * 3.1) - 0.5) * aspect * 1.2, (hash11(b * 7.7) - 0.5) * 0.9);
            }

            fragment float4 fluidFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], texture2d<float> previous [[texture(0)]]) {
                constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
                float aspect = u.resTime.x / u.resTime.y;
                float time = u.resTime.z;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float intensity = u.extra.z;
                float2 uv = in.uv;
                float2 p = (uv - 0.5) * float2(aspect, 1.0);

                // Velocity: the curl of a drifting noise potential, plus a push and swirl around the injection.
                float2 q = p * 2.2 + float2(time * 0.07, -time * 0.05);
                float e = 0.02;
                float dy = vnoise(q + float2(0.0, e)) - vnoise(q - float2(0.0, e));
                float dx = vnoise(q + float2(e, 0.0)) - vnoise(q - float2(e, 0.0));
                float2 vel = float2(dy, -dx) / (2.0 * e) * 0.0004 * (0.6 + 1.4 * energy) * intensity;
                float2 c = injectionPoint(beats, aspect);
                float2 away = p - c;
                float dist = length(away) + 1e-3;
                float reach = exp(-dist * 3.0);
                vel += (away / dist) * kick * 0.006 * reach * intensity;
                vel += float2(-away.y, away.x) / dist * (0.002 + 0.004 * energy) * reach * intensity;

                float2 back = float2(vel.x / aspect, vel.y);
                float3 col = previous.sample(linearSampler, uv - back).rgb;
                col = max(col * 0.972 - 0.002, 0.0);

                // Kick: a blob of ink at the injection point.
                // Ink is blended toward the palette colour, never added, so it stays saturated instead of blowing out.
                float blob = clamp(exp(-dot(away, away) / (0.012 + 0.02 * kick)) * kick * 0.7, 0.0, 1.0);
                col = mix(col, paletteAt(u, hash11(floor(beats) * 1.9) + beats * 0.02) * 1.15, blob);
                // Snare: a thin expanding ring in the palette's third colour.
                float ring = clamp(exp(-pow((dist - (1.0 - snare) * 0.6) * 14.0, 2.0)) * snare * 0.6, 0.0, 1.0);
                col = mix(col, u.c2.rgb * 1.15, ring);
                // The spectrum feeds plumes up from the bottom edge; hats sparkle.
                float plume = smoothstep(0.93, 1.0, uv.y) * bandAt(spectrum, uv.x);
                col = mix(col, paletteAt(u, uv.x * 0.8 + time * 0.02) * 1.1, clamp(plume * 0.35, 0.0, 1.0));
                col += u.c1.rgb * hat * hash21(floor(uv * float2(80.0, 50.0)) + floor(time * 20.0)) * 0.04 * step(0.9, hat);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }

            fragment float4 glitchFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], texture2d<float> source [[texture(0)]]) {
                constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
                float g = u.extra.w;
                float2 uv = in.uv;
                float tq = floor(u.resTime.z * 8.0);

                // Row tearing: a fraction of 36 horizontal bands slide sideways.
                float band = floor(uv.y * 36.0);
                float tear = step(1.0 - 0.55 * g, hash21(float2(band, tq)));
                float shift = (hash21(float2(band + 7.0, tq)) - 0.5) * 0.18 * g * tear;
                // Block shifts: a few 14 x 9 blocks jump.
                float2 blk = floor(uv * float2(14.0, 9.0));
                float jump = step(1.0 - 0.12 * g, hash21(blk + tq * 1.7));
                float2 bshift = float2(hash21(blk + 3.0) - 0.5, hash21(blk + 5.0) - 0.5) * 0.12 * g * jump;
                float2 suv = uv + float2(shift, 0.0) + bshift;

                float split = (0.0015 + 0.02 * g + 0.004 * u.fx.y) * u.extra.z;
                float3 col = float3(
                    source.sample(linearSampler, suv + float2(split, 0.0)).r,
                    source.sample(linearSampler, suv).g,
                    source.sample(linearSampler, suv - float2(split, 0.0)).b);

                // Pixel-sort style smear on the torn rows: bright pixels drag to the right.
                if (tear > 0.5) {
                    float3 smear = float3(0.0);
                    for (int i = 1; i <= 5; i++) {
                        smear = max(smear, source.sample(linearSampler, suv - float2(0.012 * float(i), 0.0)).rgb * (1.0 - 0.14 * float(i)));
                    }
                    col = max(col, smear * g);
                }
                col *= 1.0 - 0.06 * g * (0.5 + 0.5 * sin(uv.y * u.resTime.y * 3.14159));
                col += u.flashColor.rgb * u.extra.x * 0.3;
                float2 p = uv - 0.5;
                col *= 1.0 - 0.5 * dot(p, p);
                col = 1.0 - exp(-col * 1.7);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
