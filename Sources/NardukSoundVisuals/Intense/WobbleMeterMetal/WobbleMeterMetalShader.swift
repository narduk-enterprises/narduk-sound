#if canImport(Metal)
    /// Wobble meter (Metal): a glossy instrument panel. On the left a lit glass dial: a chrome bezel, a three-quarter
    /// arc that fills to the filter cutoff like a neon tube, eleven ticks, and a needle that sweeps a turn per wobble
    /// cycle with a fading tail over a glowing hub. On the right two segmented LED meters (peak with a hold cap, and
    /// RMS). Behind it all the spectrum stands as a dim row of soft columns, bass at the dial and highs at the meters.
    /// Bass swells the dial's glow and the hub; highs sparkle on the ticks and the meter glass; a kick flares the needle
    /// and the panel; the snare flashes the arc; the beat pulses the ticks. The Metal port of the Canvas `wobbleMeter`.
    enum WobbleMeterMetalShader {
        static let source = #"""
            static float wobbleMeterMetalWrap(float a) {
                return a - 6.2831853 * floor(a / 6.2831853);
            }

            // One segmented LED meter at x-center `cx`, as light at `p` (y down, -0.78 the top, 0.78 the bottom).
            static float3 wobbleMeterMetalLeds(
                float2 p, float cx, float level, float hold, constant IntenseUniforms &u, float3 light, float lit, float kick, float highs) {
                float hw = 0.1;
                float lx = (p.x - cx) / hw;
                if (abs(lx) > 1.25 || p.y < -0.84 || p.y > 0.84) return float3(0.0);
                float body = smoothstep(1.0, 0.92, abs(lx));
                float t = clamp((0.78 - p.y) / 1.56, 0.0, 1.0);
                float segments = 26.0;
                float cell = t * segments;
                float index = floor(cell);
                float inside = smoothstep(0.0, 0.12, fract(cell)) * smoothstep(1.0, 0.82, fract(cell));
                float z = sqrt(max(1.0 - lx * lx, 0.0));
                float2 shade = fxLight(float3(lx, 0.0, z), light, 22.0);
                float3 tint = t < 0.6 ? mix(u.c1.rgb, u.c0.rgb, t / 0.6) : mix(u.c0.rgb, u.c2.rgb, (t - 0.6) / 0.4);
                tint = mix(tint, float3(1.0), 0.18 * smoothstep(0.7, 1.0, t));
                float segMid = (index + 0.5) / segments;
                float on = smoothstep(segMid - 0.5 / segments, segMid + 0.2 / segments, level);
                on = 1.0 - smoothstep(0.0, 0.5 / segments, segMid - level);
                float cap = 1.0 - smoothstep(0.0, 0.7 / segments, abs(segMid - hold));
                float3 glass = tint * (0.05 + 0.1 * shade.x) * (0.6 + 0.8 * highs);
                float3 led = tint * (0.5 + 0.9 * shade.x) * 1.5 + float3(1.0) * shade.y * 0.4;
                float3 col = (glass + led * on * (1.0 + 0.5 * kick) + mix(tint, float3(1.0), 0.6) * cap * 1.4) * inside * body;
                // The glow of lit segments bleeding sideways into the glass around them.
                col += tint * on * exp(-max(abs(lx) - 1.0, 0.0) * 6.0) * 0.05 * smoothstep(1.25, 0.9, abs(lx));
                return col;
            }

            fragment float4 wobbleMeterMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]]) {
                float aspect = u.resTime.x / u.resTime.y;
                float intensity = u.extra.z;
                float time = u.resTime.z * intensity;
                float beats = u.resTime.w;
                float kick = u.env.x;
                float snare = u.env.y;
                float hat = u.env.z;
                float energy = u.wobble.z;
                float cutoff = clamp(u.wobble.x, 0.0, 1.0);
                float phase = u.wobble.y;
                float bass = bandAt(spectrum, 0.05);
                float highs = bandAt(spectrum, 0.8);
                float beatPulse = pow(1.0 - fract(beats), 3.0);
                float3 light = fxKeyLight();

                float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                p += u.fx.zw * 0.02 * intensity;
                float dialR = min(0.86, 0.46 * aspect);
                float2 dc = float2(-(aspect - dialR * 1.12 - 0.08), 0.0);
                float meterX = 0.5 * (dc.x + dialR * 1.12 + aspect) - 0.23;
                float2 d = p - dc;
                float r = length(d);
                float a = atan2(d.y, d.x);

                // Far: the panel's dark glass, a glow behind the dial, and the spectrum as soft columns across the width.
                float3 col = float3(0.003, 0.005, 0.012) + mix(u.c0.rgb, u.c1.rgb, 0.5) * (0.02 + 0.05 * energy + 0.1 * bass + 0.05 * kick) * exp(-dot(d, d) / (dialR * dialR) * 0.9);
                {
                    float sx = clamp((in.uv.x - 0.03) / 0.94, 0.0, 0.999) * 64.0;
                    int i = int(sx);
                    float v = pow(spectrum[i], 0.7);
                    float colw = smoothstep(0.0, 0.25, fract(sx)) * smoothstep(1.0, 0.75, fract(sx));
                    float top = 1.0 - 0.8 * v;
                    float inside = smoothstep(top, top + 0.02, in.uv.y) * colw;
                    col += paletteAt(u, float(i) / 63.0 * 0.66) * inside * (0.05 + 0.35 * (in.uv.y - top)) * (1.0 + 0.5 * kick);
                }
                col += mix(float3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(float2(in.uv.x * aspect, in.uv.y - time * 0.01), 26.0, 3.0, time) * (0.2 + 0.7 * highs);

                // The dial: a chrome bezel, a dark face, the arc track and its lit fill.
                float arcR = dialR * 0.82;
                float arcW = dialR * 0.055;
                if (r < dialR * 1.12) {
                    // Bezel: a torus, lit.
                    float br = (r - dialR * 0.97) / (dialR * 0.07);
                    float bezel = smoothstep(1.0, 0.9, abs(br));
                    float3 bn = float3(normalize(d) * br, sqrt(max(1.0 - br * br, 0.0)));
                    float2 bl = fxLight(bn, light, 40.0);
                    float3 chrome = mix(float3(0.02, 0.025, 0.035), mix(u.c1.rgb, float3(1.0), 0.5) * 0.7, bl.x * 0.7) + float3(1.0) * bl.y * 0.7;
                    col = mix(col, chrome, bezel * 0.95);
                    // Face.
                    float face = smoothstep(dialR * 0.97, dialR * 0.94, r);
                    float3 faceCol = mix(float3(0.004, 0.006, 0.014), mix(u.c0.rgb, u.c1.rgb, 0.5) * 0.12, exp(-r * r / (dialR * dialR) * 2.5)) * (0.7 + 0.5 * kick + 0.5 * bass);
                    col = mix(col, faceCol, face);

                    float ta = wobbleMeterMetalWrap(a - 2.3561945);
                    float sweep = 4.712389;
                    float inSweep = step(ta, sweep);
                    float fraction = clamp(ta / sweep, 0.0, 1.0);
                    float lx = (r - arcR) / arcW;
                    float tube = smoothstep(1.0, 0.8, abs(lx)) * inSweep;
                    float tz = sqrt(max(1.0 - lx * lx, 0.0));
                    float2 tl = fxLight(float3(normalize(d) * lx, tz), light, 24.0);
                    float3 arcTint = mix(u.c1.rgb, u.c2.rgb, fraction);
                    float lit = smoothstep(cutoff + 0.004, cutoff - 0.004, fraction);
                    float3 track = float3(0.02, 0.03, 0.045) * (0.4 + tl.x) + float3(1.0) * tl.y * 0.06;
                    float3 fill = arcTint * (0.35 + 0.9 * tl.x) * 1.7 + float3(1.0) * tl.y * 0.5;
                    col += (track * (1.0 - lit) + fill * lit * (1.0 + 0.7 * bass + 0.6 * snare)) * tube * face;
                    // The glow of the filled arc on the face.
                    col += arcTint * lit * inSweep * exp(-abs(lx) * 0.9) * 0.1 * (1.0 + 2.5 * bass) * face;
                    // The cutoff head: a bright bead at the end of the fill.
                    float headA = 2.3561945 + sweep * cutoff;
                    float2 head = dc + arcR * float2(cos(headA), sin(headA));
                    col += mix(arcTint, float3(1.0), 0.6) * exp(-dot(p - head, p - head) * 1400.0) * 1.2 * step(0.01, cutoff);

                    // Eleven ticks inside the arc.
                    float tickPos = ta / sweep * 10.0;
                    float tickAngle = abs(fract(tickPos + 0.5) - 0.5) * sweep / 10.0 * r;
                    float tickMask = exp(-pow(tickAngle / 0.0045, 2.0)) * smoothstep(arcR - arcW * 3.6, arcR - arcW * 3.0, r) * smoothstep(arcR - arcW * 1.6, arcR - arcW * 2.4, r) * inSweep;
                    float tickLit = step(fraction, cutoff);
                    col += mix(float3(0.5, 0.6, 0.8), arcTint, tickLit) * tickMask * (0.3 + 0.8 * tickLit * (0.4 + 0.6 * beatPulse) + 0.7 * highs * hat) * face;
                }

                // The needle: it turns once per LFO cycle, with a tail of afterimage behind it, over a glowing hub.
                {
                    float na = -1.5707963 + phase * 6.2831853;
                    float2 tip = dc + (dialR * 0.78) * float2(cos(na), sin(na));
                    float needleD = fxSegment(p, dc, tip);
                    float2 nb = fxBeam(needleD, 0.0065 * (dialR / 0.74));
                    float da = wobbleMeterMetalWrap(a - na + 3.14159265) - 3.14159265;
                    float trail = exp(da * 6.0) * step(da, 0.0) * step(-1.2, da) * step(r, dialR * 0.78) * smoothstep(0.0, dialR * 0.12, r);
                    float3 needleTint = mix(u.c2.rgb, float3(1.0), 0.35);
                    col += (needleTint * nb.x * 1.8 + u.c2.rgb * nb.y * 1.2) * (1.0 + 0.9 * kick);
                    col += u.c2.rgb * trail * 0.45 * (0.6 + 0.8 * energy) * smoothstep(dialR * 0.1, dialR * 0.35, r);
                    col += mix(u.c2.rgb, float3(1.0), 0.6) * exp(-dot(p - tip, p - tip) * 2600.0) * 1.1;
                    // The hub: a lit ball whose glow follows the bass.
                    float hubR = dialR * 0.085;
                    float2 rel = d / hubR;
                    if (dot(rel, rel) < 1.0) {
                        float z = sqrt(1.0 - dot(rel, rel));
                        float2 hl = fxLight(float3(rel, z), light, 30.0);
                        col = mix(col, mix(float3(0.02), u.c2.rgb, 0.4 + 0.5 * bass) * (0.2 + hl.x) + float3(1.0) * hl.y * 0.8, 0.95);
                    }
                    col += u.c2.rgb * exp(-max(r - hubR, 0.0) * 22.0) * (0.04 + 0.12 * bass) * smoothstep(dialR * 0.3, 0.0, r - hubR);
                }

                // A dome of glass over the dial: one soft highlight.
                {
                    float2 g = (d - float2(-0.25, -0.34) * dialR) / dialR;
                    col += float3(0.8, 0.9, 1.0) * exp(-dot(g * float2(1.0, 2.4), g * float2(1.0, 2.4)) * 3.0) * 0.035 * step(r, dialR * 0.95);
                }

                // The two LED meters, from the peak / RMS / hold the state carries.
                col += wobbleMeterMetalLeds(p, meterX, aux[112], aux[114], u, light, 1.0, kick, highs);
                col += wobbleMeterMetalLeds(p, meterX + 0.46, aux[113], -1.0, u, light, 1.0, kick, highs);
                col += u.c0.rgb * exp(-pow((p.x - meterX - 0.23) * 40.0, 2.0)) * 0.012 * step(abs(p.y), 0.78);

                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, in.uv * 2.0 - 1.0, 0.12);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
