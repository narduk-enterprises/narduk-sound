#if canImport(Metal)
    import NardukMusicCore

    /// Pads (Metal): one lit glass pad per instrument on a dark panel. Each pad is a bevelled slab with a specular
    /// edge whose face fills with its palette color (instruments of one role share a hue) and a hot center when the
    /// instrument fires; the light spills into the gaps and the neighbouring pads, and a shock ring leaves the pad
    /// and fades as it decays. Idle pads breathe a little and take a backlight from the spectrum at their place on the
    /// panel (bass on the left, highs on the right); a beat sweep crosses the panel every bar; a kick lights the panel
    /// and the spill along the bottom edge. The Metal port of the Canvas `pads`.
    enum PadsMetalShader {
        /// Where on the palette an instrument's pad sits (the same table as the Canvas `pads`).
        static func position(_ instrument: Instrument) -> Float {
            switch instrument {
            case .kick, .vox: 0
            case .snare, .scratch: 0.17
            case .hat, .openHat, .riser: 0.34
            case .wobble, .laser: 0.5
            case .sub, .keys: 0.67
            case .glitch, .tapeStop, .impact: 0.84
            case .acousticGuitar, .strum: 0.25
            case .electricGuitar, .electricStrum: 0.75
            case .bassGuitar: 0.58
            case .vocal, .vocalChop, .vocalSample: 0.92
            case .cut: 0.84
            }
        }

        /// The instruments that get a pad: the same set as the Canvas `pads`. The vocals (#1641) and the master cut have
        /// no pad yet: adding them would reflow every app's grid and its golden image.
        static let instruments = Instrument.allCases.filter {
            ![.vocal, .vocalChop, .vocalSample, .cut].contains($0)
        }

        /// The MSL tables: the palette position and the brightness lane of each pad, in `Instrument.allCases` order.
        static var tables: String {
            let all = instruments
            let positions = all.map { String(position($0)) }.joined(separator: ", ")
            let lanes = all.map { String($0.index) }.joined(separator: ", ")
            return """
                constant constexpr int padsMetalCount = \(all.count);
                constant constexpr float padsMetalPosition[\(all.count)] = { \(positions) };
                constant constexpr int padsMetalLane[\(all.count)] = { \(lanes) };
                """
        }

        static let source =
            tables + #"""

                // The centre of pad `i` and the half-size of every pad, for a grid of `cols` x `rows` over the panel.
                static float2 padsMetalCenter(int i, int cols, int rows, float aspect, thread float2 &hs) {
                    float margin = 0.1;
                    float gap = 0.05;
                    float2 area = float2(2.0 * aspect - 2.0 * margin, 2.0 - 2.0 * margin);
                    float cw = (area.x - gap * float(cols - 1)) / float(cols);
                    float ch = (area.y - gap * float(rows - 1)) / float(rows);
                    hs = float2(cw, ch) * 0.5;
                    int cx = i % cols;
                    int cy = i / cols;
                    return float2(-aspect + margin + cw * 0.5 + float(cx) * (cw + gap), -1.0 + margin + ch * 0.5 + float(cy) * (ch + gap));
                }

                fragment float4 padsMetalFragment(
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
                    float bass = bandAt(spectrum, 0.05);
                    float highs = bandAt(spectrum, 0.8);
                    float3 light = fxKeyLight();

                    float2 p = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0;
                    p += u.fx.zw * 0.02 * intensity;
                    int cols = aspect >= 1.5 ? 7 : (aspect >= 0.9 ? 5 : 4);
                    int rows = (padsMetalCount + cols - 1) / cols;
                    float sweep = fract(beats / 4.0);
                    float x01 = in.uv.x;

                    // Far: the dark panel, a faint brushed grain, bokeh, and the light spilling up from the bottom edge,
                    // shaped by the spectrum.
                    float3 col = float3(0.004, 0.006, 0.013) + mix(u.c0.rgb, u.c1.rgb, 0.5) * 0.012 * (1.0 - in.uv.y);
                    col *= 0.85 + 0.15 * vnoise(float2(p.x * 90.0, p.y * 2.0));
                    {
                        float sx = clamp((x01 - 0.02) / 0.96, 0.0, 0.999) * 64.0;
                        float v = pow(spectrum[int(sx)], 0.7);
                        col += paletteAt(u, sx / 64.0 * 0.66) * v * exp(-(1.0 - in.uv.y) * 7.0) * (0.12 + 0.2 * kick) * smoothstep(0.0, 1.0, v);
                    }
                    {
                        float2 bp = float2(x01 * aspect, in.uv.y - time * 0.01) * 6.0;
                        float2 id = floor(bp);
                        float h = hash21(id + 4.0);
                        float2 c = id + 0.5 + (float2(hash21(id + 1.7), hash21(id + 9.1)) - 0.5) * 0.6;
                        float bokeh = smoothstep(0.3, 0.08, length(bp - c)) * step(0.75, h) * (0.5 + 0.5 * sin(time * 0.7 + h * 40.0));
                        col += paletteAt(u, hash21(id + 2.0) * 0.8) * bokeh * (0.02 + 0.05 * hat + 0.03 * bass);
                    }
                    col += float3(0.8, 0.9, 1.0) * fxStars(float2(x01 * aspect, in.uv.y), 30.0, 6.0, time) * (0.2 + 0.6 * highs);

                    // The pads: this pixel's own pad and its eight neighbours (their light spills across the gap).
                    float margin = 0.1;
                    float gap = 0.05;
                    float cw = (2.0 * aspect - 2.0 * margin - gap * float(cols - 1)) / float(cols);
                    float chh = (2.0 - 2.0 * margin - gap * float(rows - 1)) / float(rows);
                    int gx = clamp(int(floor((p.x + aspect - margin) / (cw + gap))), 0, cols - 1);
                    int gy = clamp(int(floor((p.y + 1.0 - margin) / (chh + gap))), 0, rows - 1);
                    for (int dy = -1; dy <= 1; dy++) {
                        for (int dx = -1; dx <= 1; dx++) {
                            int cx = gx + dx;
                            int cy = gy + dy;
                            if (cx < 0 || cx >= cols || cy < 0 || cy >= rows) continue;
                            int i = cy * cols + cx;
                            float2 hs;
                            float2 c = padsMetalCenter(i, cols, rows, aspect, hs);
                            if (i >= padsMetalCount) {
                                // An empty slot: a recessed socket with a faint lit lip.
                                float2 sq = p - c;
                                float socket = fxRoundBox(sq, hs, min(hs.x, hs.y) * 0.28);
                                if (socket < 0.0) {
                                    col = col * 0.5 + mix(u.c0.rgb, u.c1.rgb, 0.5) * exp(-pow(socket / 0.006, 2.0)) * 0.05 * (0.6 + 0.8 * energy);
                                }
                                continue;
                            }
                            float level = clamp(aux[76 + padsMetalLane[i]], 0.0, 1.0);
                            float3 tint = paletteAt(u, padsMetalPosition[i]);
                            tint = tint * (1.0 + 0.45 * (tint / max(dot(tint, float3(0.333)), 0.05) - 1.0));
                            float2 q = p - c;
                            float radius = min(hs.x, hs.y) * 0.28;
                            float sdf = fxRoundBox(q, hs, radius);
                            float back = pow(bandAt(spectrum, clamp((c.x / aspect + 1.0) * 0.5, 0.0, 1.0)), 0.7);
                            float breathe = 0.5 + 0.5 * sin(time * 0.9 + float(i) * 1.7);
                            float sweepLit = exp(-pow((((c.x / aspect) + 1.0) * 0.5 - sweep) * 9.0, 2.0));

                            // Light leaving the pad: a bloom into the gaps and onto the neighbours, and its shock ring.
                            float bloomK = 0.5 + 3.0 * level * level;
                            col += tint * exp(-max(sdf, 0.0) * 14.0) * (level * 0.8 + 0.02 * back) * (1.0 + bloomK * 0.0) * (sdf > 0.0 ? 1.0 : 0.0);
                            if (level > 0.04) {
                                float ringR = min(hs.x, hs.y) * (0.9 + 1.5 * (1.0 - level));
                                float ring = exp(-pow((length(q) - ringR) / 0.012, 2.0));
                                col += mix(tint, float3(1.0), 0.4) * ring * level * level * 0.45 * (sdf > 0.0 ? 1.0 : 0.0);
                            }

                            if (sdf < 0.0) {
                                float2 e = float2(0.004, 0.0);
                                float2 grad = float2(
                                    fxRoundBox(q + e.xy, hs, radius) - fxRoundBox(q - e.xy, hs, radius),
                                    fxRoundBox(q + e.yx, hs, radius) - fxRoundBox(q - e.yx, hs, radius)) / (2.0 * e.x);
                                float bevel = 1.0 - smoothstep(0.0, 0.07, -sdf);
                                float3 n = normalize(float3(grad * bevel * 0.9, 1.0));
                                float2 lit = fxLight(n, light, 34.0);
                                float2 rel = q / hs;
                                float core = exp(-dot(rel, rel) * 1.3);
                                float3 glass = tint * (0.03 + 0.14 * back * (0.6 + 0.4 * breathe) + 0.05 * sweepLit + 0.025 * kick);
                                float3 fill = tint * level * (0.55 + 1.5 * core) + mix(tint, float3(1.0), 0.8) * level * level * core * 0.9;
                                float3 face = (glass + fill) * (0.45 + 0.7 * lit.x) * (0.78 + 0.3 * clamp(-rel.y, -1.0, 1.0)) * (1.0 - 0.35 * smoothstep(0.0, 0.1, -sdf) * 0.0);
                                face *= 0.6 + 0.4 * smoothstep(0.0, 0.12, -sdf);
                                face += float3(1.0) * lit.y * (0.2 + 0.5 * level);
                                // A glassy highlight along the upper edge, and a bright rim that follows the pad's level.
                                face += float3(1.0) * exp(-pow((q.y / hs.y + 0.78) * 7.0, 2.0)) * smoothstep(1.0, 0.5, abs(q.x / hs.x)) * (0.05 + 0.05 * level);
                                face += tint * exp(-pow(sdf / 0.007, 2.0)) * (0.25 + 1.1 * level);
                                // A diagonal streak of reflected light across the glass.
                                face += float3(1.0) * exp(-pow((rel.x * 0.8 + rel.y * 0.6 - 0.35) * 5.0, 2.0)) * (0.035 + 0.05 * level) * smoothstep(0.0, 0.05, -sdf);
                                // The pad's role LED, top left, and its level strip along the bottom edge.
                                face += tint * exp(-dot(q - float2(-hs.x * 0.8, -hs.y * 0.72), q - float2(-hs.x * 0.8, -hs.y * 0.72)) * 5000.0) * (0.5 + 0.6 * level);
                                face += tint * smoothstep(0.012, 0.0, abs(q.y - hs.y * 0.82)) * step(abs(q.x), hs.x * 0.7) * step(q.x, -hs.x * 0.7 + 1.4 * hs.x * level) * (0.1 + 0.5 * level);
                                col = face;
                            }
                        }
                    }

                    // A snare brightens the whole panel's edge a moment; the kick lit the panel above.
                    col += mix(u.c2.rgb, float3(1.0), 0.3) * snare * 0.02 * smoothstep(0.6, 1.1, abs(in.uv.y * 2.0 - 1.0));

                    col = fxFlash(col, u, 0.2);
                    col = fxTonemap(col, 1.3);
                    col = fxVignette(col, in.uv * 2.0 - 1.0, 0.12);
                    return float4(clamp(col, 0.0, 1.0), 1.0);
                }
                """#
    }
#endif
