#if canImport(Metal)
    /// Piano roll (Metal): a note waterfall that flows left to right into a lit keyboard. Each note is a glass bar on
    /// its pitch row, lit from a cylinder normal in its pitch class's palette color, hot at the strike (the left end of
    /// a held note) and cooling toward its tail; older notes dim into the dark on the left, and a note still sounding
    /// runs into the playhead, where it flares and lights its key. White and black piano-key rows are shaded apart with
    /// a line at each C. With no notes from the source the 12 analysis chroma rows draw instead, as cells. Behind it a
    /// glow stands at the playhead and slow dust drifts the way the notes flow. The bass swells the playhead glow,
    /// the highs light the dust, a kick flares the playhead, the beat pulses it. The Metal port of the Canvas
    /// `pianoRoll`.
    enum PianoRollMetalShader {
        static let source = #"""
            static float pianoRollMetalCell(constant uchar *top, constant uchar *bottom, int row, int column) {
                if (row < 0 || row >= 88 || column < 0 || column >= 64) return 0.0;
                return float(row < 44 ? top[row * 64 + column] : bottom[(row - 44) * 64 + column]);
            }

            fragment float4 pianoRollMetalFragment(
                IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
                constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]],
                constant float *aux [[buffer(4)]], constant uchar *rollTop [[buffer(6)]], constant uchar *rollBottom [[buffer(7)]]) {
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
                float beatPulse = pow(1.0 - fract(beats), 3.0);
                float3 light = fxKeyLight();

                float hasNotes = aux[111];
                float low = hasNotes > 0.5 ? aux[116] - 21.0 : 0.0;
                float span = hasNotes > 0.5 ? max(aux[117], 12.0) : 12.0;

                float2 uv = in.uv;
                float x0 = 0.015;
                float playX = 0.925;
                float keyX = 0.985;
                float y0 = 0.03;
                float y1 = 0.97;
                float colWidth = (playX - x0) / 64.0;
                float rowHeight = (y1 - y0) / span;
                float px = u.resTime.y;
                float2 p = (uv - 0.5) * float2(aspect, 1.0) * 2.0;

                // Far: a glow standing at the playhead that follows the bass, and dust drifting the way the notes flow.
                float3 col = float3(0.003, 0.005, 0.012);
                col += mix(u.c1.rgb, u.c0.rgb, 0.3) * exp(-pow((uv.x - 0.88) * 2.4, 2.0) - pow((uv.y - 0.5) * 1.5, 2.0)) * (0.03 + 0.07 * energy + 0.2 * bass + 0.12 * kick);
                col += mix(float3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(float2(uv.x * aspect - time * 0.04, uv.y), 24.0, 12.0, time) * (0.2 + 0.9 * highs + 0.4 * hat);
                {
                    float2 bp = float2(uv.x * aspect - time * 0.08, uv.y) * 4.0;
                    float2 id = floor(bp);
                    float h = hash21(id + 6.0);
                    float2 c = id + 0.5 + (float2(hash21(id + 2.2), hash21(id + 7.7)) - 0.5) * 0.6;
                    float bokeh = smoothstep(0.34, 0.1, length(bp - c)) * step(0.8, h) * (0.5 + 0.5 * sin(time * 0.6 + h * 40.0));
                    col += paletteAt(u, hash21(id + 4.0)) * bokeh * (0.02 + 0.03 * highs + 0.03 * bass);
                }

                bool inArea = uv.x >= x0 && uv.x <= keyX && uv.y >= y0 && uv.y <= y1;
                if (inArea) {
                    float rowF = (y1 - uv.y) / (y1 - y0) * span;
                    int j = int(floor(rowF));
                    float ry = fract(rowF) - 0.5;
                    int row = int(low) + j;
                    int note = row + 21;
                    int pc = ((note % 12) + 12) % 12;
                    bool blackKey = pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10;
                    bool chroma = hasNotes < 0.5;
                    if (chroma) { row = j; pc = j; blackKey = false; }
                    float3 tint = paletteAt(u, float(pc) / 12.0);
                    tint = tint * (1.0 + 0.45 * (tint / max(dot(tint, float3(0.333)), 0.05) - 1.0));

                    // The rows: piano-key shading, and a line at each C.
                    float roll = clamp((uv.x - x0) / (playX - x0), 0.0, 1.0);
                    if (uv.x < playX) {
                        col += mix(u.c0.rgb, u.c1.rgb, 0.5) * (blackKey ? 0.006 : 0.03) * (0.5 + 0.5 * roll);
                                        float rowLine = exp(-pow((abs(ry) - 0.5) * rowHeight * px * 0.9, 2.0));
                        col += u.c0.rgb * rowLine * (pc == 0 && !chroma ? 0.16 : 0.02) * (0.5 + 0.5 * roll);
                    }

                    // Glow from the notes around this pixel, in their own colors.
                    int column = int(floor((uv.x - x0) / colWidth));
                    if (uv.x < playX + 0.04) {
                        float3 glow = float3(0.0);
                        for (int dr = -1; dr <= 1; dr++) {
                            int nr = chroma ? clamp(j + dr, 0, 11) : row + dr;
                            if (chroma && (j + dr < 0 || j + dr > 11)) continue;
                            int npc = chroma ? nr : (((nr + 21) % 12) + 12) % 12;
                            float3 ntint = paletteAt(u, float(npc) / 12.0);
                            for (int dc = -2; dc <= 2; dc++) {
                                float v = pianoRollMetalCell(rollTop, rollBottom, nr, min(column + dc, 63)) / 255.0;
                                if (v <= 0.0) continue;
                                float dist2 = pow(float(dr) - ry, 2.0) + pow((float(dc) + 0.5 - fract((uv.x - x0) / colWidth)) * colWidth / rowHeight, 2.0);
                                glow += ntint * v * exp(-dist2 * 1.3);
                            }
                        }
                        col += glow * 0.14 * (0.4 + 0.6 * roll) * (1.0 + 0.6 * kick);
                    }

                    // The note under this pixel, as one bar from its strike to its tail.
                    if (uv.x < playX && column >= 0 && column < 64) {
                        float cell = pianoRollMetalCell(rollTop, rollBottom, row, column);
                        if (cell > 0.0) {
                            int start = column;
                            if (!chroma && cell < 200.0) {
                                for (int s = column - 1; s >= 0; s--) {
                                    float v = pianoRollMetalCell(rollTop, rollBottom, row, s);
                                    if (v <= 0.0) { start = s + 1; break; }
                                    start = s;
                                    if (v >= 200.0) break;
                                }
                            }
                            int end = column;
                            if (!chroma) {
                                for (int e = column + 1; e < 64; e++) {
                                    float v = pianoRollMetalCell(rollTop, rollBottom, row, e);
                                    if (v <= 0.0 || v >= 200.0) break;
                                    end = e;
                                }
                            }
                            float left = x0 + float(start) * colWidth + 0.0006;
                            float right = x0 + float(end + 1) * colWidth - 0.0006;
                            float cy = y1 - (float(j) + 0.5) * rowHeight;
                            float halfH = rowHeight * 0.46;
                            float2 box = float2((right - left) * 0.5 * aspect, halfH);
                            float2 q = float2((uv.x - (left + right) * 0.5) * aspect, uv.y - cy);
                            float sdf = fxRoundBox(q, box, min(halfH, 0.01 * aspect) * 0.9);
                            if (sdf < 0.004) {
                                float ly = clamp(q.y / halfH, -1.0, 1.0);
                                float z = sqrt(max(1.0 - ly * ly, 0.0));
                                float2 lit = fxLight(float3(0.0, ly * 0.9, z), light, 24.0);
                                float level = chroma ? smoothstep(0.1, 0.7, cell / 255.0) : 1.0;
                                float along = clamp((uv.x - left) / max(right - left, 1e-4), 0.0, 1.0);
                                float headGlow = exp(-(uv.x - left) / (colWidth * 1.6)) * (chroma ? 0.0 : 1.0);
                                bool live = !chroma && end == 63;
                                float3 body = tint * (0.2 + 0.9 * lit.x) * (0.7 + 0.5 * (1.0 - along * 0.5)) * 1.5;
                                body += mix(tint, float3(1.0), 0.8) * headGlow * 0.9;
                                body += float3(1.0) * lit.y * 0.4;
                                body += mix(tint, float3(1.0), 0.6) * (live ? along * 0.5 * (0.6 + 0.6 * beatPulse) : 0.0);
                                float ageFade = 0.3 + 0.7 * smoothstep(0.0, 0.9, roll);
                                col += body * ageFade * level * smoothstep(0.003, -0.003, sdf);
                            }
                        }
                    }
                }

                // The playhead: a beam that pulses with the beat, and the keyboard it runs into.
                {
                    float beam = exp(-pow((uv.x - playX) * aspect / 0.0045, 2.0)) * step(y0, uv.y) * step(uv.y, y1);
                    col += mix(u.c2.rgb, float3(1.0), 0.45) * beam * (0.28 + 0.3 * beatPulse + 0.8 * kick);
                    col += u.c2.rgb * exp(-abs(uv.x - playX) * aspect * 18.0) * 0.04 * (0.4 + 2.5 * bass) * step(y0, uv.y) * step(uv.y, y1);
                    // Keys: white keys fill the strip, black keys are shorter and darker; a key lights while its note sounds.
                    if (uv.x > playX && uv.x <= keyX && uv.y >= y0 && uv.y <= y1) {
                        float rowF = (y1 - uv.y) / (y1 - y0) * span;
                        int j = int(floor(rowF));
                        float ry = fract(rowF) - 0.5;
                        bool chroma = hasNotes < 0.5;
                        int row = chroma ? j : int(low) + j;
                        int pc = chroma ? j : ((((row + 21) % 12) + 12) % 12);
                        bool blackKey = !chroma && (pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10);
                        float v = pianoRollMetalCell(rollTop, rollBottom, row, 63) / 255.0;
                        float3 tint = paletteAt(u, float(pc) / 12.0);
                        float across = (uv.x - playX) / (keyX - playX);
                        float keyLength = blackKey ? 0.62 : 1.0;
                        float body = step(across, keyLength) * smoothstep(0.5, 0.42, abs(ry));
                        float shade = 0.9 - 0.4 * across;
                        float3 keyCol = (blackKey ? float3(0.015, 0.018, 0.026) : float3(0.07, 0.08, 0.1)) * shade;
                        keyCol = mix(keyCol, tint * (0.5 + 1.2 * v) + float3(1.0) * v * 0.4, smoothstep(0.0, 0.2, v));
                        keyCol += float3(1.0) * exp(-pow((ry + 0.35) * 8.0, 2.0)) * 0.02 * (1.0 - float(blackKey));
                        col = mix(col, keyCol, body);
                        col += tint * v * exp(-across * 1.5) * 0.15;
                    }
                    // A flare where a sounding note meets the playhead.
                    if (uv.y >= y0 && uv.y <= y1 && uv.x < keyX) {
                        float rowF = (y1 - uv.y) / (y1 - y0) * span;
                        int j = int(floor(rowF));
                        bool chroma = hasNotes < 0.5;
                        int row = chroma ? j : int(low) + j;
                        int pc = chroma ? j : ((((row + 21) % 12) + 12) % 12);
                        float v = pianoRollMetalCell(rollTop, rollBottom, row, 63) / 255.0;
                        float2 d = float2((uv.x - playX) * aspect, (fract(rowF) - 0.5) * rowHeight);
                        col += mix(paletteAt(u, float(pc) / 12.0), float3(1.0), 0.5) * v * exp(-dot(d, d) / (rowHeight * rowHeight * 2.5)) * (0.5 + 0.7 * kick);
                    }
                }

                col = fxFlash(col, u, 0.2);
                col = fxTonemap(col, 1.3);
                col = fxVignette(col, p, 0.1);
                return float4(clamp(col, 0.0, 1.0), 1.0);
            }
            """#
    }
#endif
