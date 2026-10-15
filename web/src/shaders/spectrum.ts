import type { VisualizerPort } from "./port.js";

/**
 * Spectrum: the 64 log-spaced bands as a row of glass tubes filled with liquid light on a glossy floor that mirrors
 * them, a dim drifting echo behind, rising dust and bokeh, peak-hold beads and a floor seam that pulses on the beat.
 * Ported from Sources/NardukSoundVisuals/Intense/SpectrumMetal/SpectrumMetalShader.swift.
 */
export const spectrum: VisualizerPort = {
  id: "spectrum",
  title: "Spectrum",
  metalSource: "Sources/NardukSoundVisuals/Intense/SpectrumMetal/SpectrumMetalShader.swift",
  metalSha256: "3b20accf87577189262e3ecc393738cce76f524966c57ed92b15accf551b7490",
  glsl: `
vec3 spectrumMetalRamp(float band, float t) {
    vec3 hue = paletteAt(band * 0.66);
    vec3 sat = hue * (1.0 + 0.5 * (hue / max(dot(hue, vec3(0.333)), 0.05) - 1.0));
    return mix(sat * 0.3, mix(sat, vec3(1.0), 0.4), pow(t, 0.8));
}

vec3 spectrumMetalTubes(float x, float y, float base, float usable, float spread, float time, float kick, vec3 light) {
    float sx = (x - 0.04) / 0.92 * 64.0;
    if (sx < 0.0 || sx >= 64.0) return vec3(0.0);
    int i = int(sx);
    float lx = (fract(sx) - 0.5) / spread;
    float edge = smoothstep(1.0, 0.8, abs(lx));
    if (edge <= 0.0) return vec3(0.0);
    float v = min(pow(spectrumAt(i), 0.7), 1.0);
    float top = base - max(0.012, usable * v) + 0.0045 * sin(time * 6.0 + float(i) * 0.9) * (0.4 + v);
    float t = clamp((base - y) / usable, 0.0, 1.0);
    float z = sqrt(max(1.0 - lx * lx, 0.0));
    vec2 lit = fxLight(vec3(lx, 0.0, z), light, 26.0);
    vec3 tint = spectrumMetalRamp(float(i) / 63.0, t);
    vec3 col = tint * (pow(abs(lx), 3.0) * 0.06 + 0.012) * step(0.0, base - y) * step(y, base) * step(0.0, y - (base - usable * 1.02));
    if (y > top && y < base) {
        float body = (0.22 + 0.78 * pow(t, 0.8)) * lit.x;
        float core = exp(-lx * lx * 2.5);
        col = tint * body * 1.7 + mix(tint, vec3(1.0), 0.7) * core * pow(t, 1.6) * 0.9 * (0.6 + 0.6 * v);
        col += vec3(1.0) * lit.y * 0.45;
        col += vec3(1.0) * exp(-sq((lx + 0.42) * 7.0)) * (0.1 + 0.2 * t) * (1.0 - 0.5 * v);
        float meniscus = exp(-sq((y - top) * 150.0));
        col += mix(tint, vec3(1.0), 0.7) * meniscus * 0.9;
        col *= 1.0 + 0.45 * kick * (1.0 - t) * (1.0 - float(i) / 40.0);
    }
    return col * edge;
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float intensity = u.extra.z;
    float time = u.resTime.z * intensity;
    float travel = u.misc.z * intensity;
    float beats = u.resTime.w;
    float kick = u.env.x;
    float snare = u.env.y;
    float hat = u.env.z;
    float energy = u.wobble.z;
    float drop = u.misc.y;
    float bass = bandAt(0.05);
    float mids = bandAt(0.4);
    float highs = bandAt(0.8);
    float beatPulse = pow(1.0 - fract(beats), 3.0);

    vec2 uv = vUv;
    uv += u.fx.zw * 0.004 * intensity;
    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    float base = 0.76;
    float usable = 0.56 + 0.05 * drop;
    float spread = 0.34 + 0.1 * drop;
    vec3 light = fxKeyLight();

    vec3 col = vec3(0.004, 0.007, 0.018) + u.c1.rgb * 0.02 * smoothstep(0.2, 1.0, uv.y);
    col += mix(u.c0.rgb, u.c1.rgb, 0.6) * exp(-sq((uv.y - base + 0.3) * 2.6)) * (0.025 + 0.05 * energy + 0.06 * kick);

    {
        float fs = uv.x * 40.0 + travel * 0.05;
        float fi = floor(fs);
        float fl = (fract(fs) - 0.5) / 0.28;
        float band = fract(fi / 40.0);
        float fv = 0.5 * (bandAt(band) + bandAt(min(band + 0.03, 1.0)));
        float fbase = base - 0.05;
        float ftop = fbase - usable * 0.5 * fv;
        float inside = step(ftop, uv.y) * step(uv.y, fbase) * smoothstep(1.0, 0.7, abs(fl));
        float ft = clamp((fbase - uv.y) / (usable * 0.5), 0.0, 1.0);
        col += spectrumMetalRamp(band, ft * 0.8) * inside * (0.05 + 0.1 * ft) * (0.6 + 0.5 * energy);
    }

    col += mix(vec3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(vec2(uv.x * aspect, uv.y + travel * 0.015), 22.0, 5.0, time) * (0.25 + 0.6 * highs) * smoothstep(0.1, 0.6, base - uv.y + 0.2);
    {
        vec2 bp = vec2(uv.x * aspect, uv.y + travel * 0.03) * 5.0;
        vec2 id = floor(bp);
        float h = hash21(id + 11.0);
        vec2 c = id + 0.5 + (vec2(hash21(id + 3.3), hash21(id + 8.1)) - 0.5) * 0.6;
        float radius = 0.12 + 0.22 * hash21(id + 2.2);
        float d = length(bp - c);
        float bokeh = smoothstep(radius, radius * 0.4, d) * step(0.72, h) * (0.4 + 0.6 * sin(time * 0.8 + h * 30.0));
        col += spectrumMetalRamp(hash21(id + 5.5), 0.6) * bokeh * (0.025 + 0.05 * hat + 0.04 * bass);
    }

    if (uv.y < base) {
        col += spectrumMetalTubes(uv.x, uv.y, base, usable, spread, time, kick, light);
    } else {
        float depth = uv.y - base;
        float ripple = 0.0012 * sin(depth * 70.0 - time * 4.0) * (0.5 + highs);
        vec3 mirror = spectrumMetalTubes(uv.x + ripple, base - depth * 1.15, base, usable, spread, time, kick, light);
        float sheen = 0.5 + 0.5 * sin(depth * 140.0 + time * 2.0);
        col += mirror * exp(-depth * 10.0) * (0.3 + 0.12 * sheen);
    }

    {
        float sx = (uv.x - 0.04) / 0.92 * 64.0;
        float env = pow(bandAt(clamp(sx / 64.0, 0.0, 1.0)), 0.7);
        float envTop = base - usable * env;
        float above = max(envTop - uv.y, 0.0);
        float below = max(uv.y - base, 0.0);
        float fall = uv.y < base ? exp(-above * 9.0) : exp(-below * 24.0) * 0.45;
        vec3 glow = spectrumMetalRamp(clamp(sx / 64.0, 0.0, 1.0), 0.5 + 0.4 * env);
        col += glow * fall * env * (0.16 + 0.1 * bass) * smoothstep(0.0, 0.05, sx + 1.0) * (1.0 + 0.6 * kick);
    }

    if (uv.y < base) {
        float sx = (uv.x - 0.04) / 0.92 * 64.0;
        if (sx >= 0.0 && sx < 64.0) {
            int i = int(sx);
            float lx = (fract(sx) - 0.5) / spread;
            float level = max(pow(auxAt(i), 0.7), pow(spectrumAt(i), 0.7));
            float capY = base - usable * min(level, 1.0) - 0.022;
            float slot = 0.92 / 64.0 * aspect;
            float sdf = fxRoundBox(vec2(lx * spread * slot, uv.y - capY), vec2(spread * slot * 0.8, 0.0022), 0.0022);
            vec2 beam = vec2(exp(-sq(max(sdf, 0.0) * 260.0)), exp(-max(sdf, 0.0) * 55.0) * 0.4);
            vec3 capTint = mix(spectrumMetalRamp(float(i) / 63.0, 1.0), vec3(1.0), 0.4);
            col += (capTint * beam.y * 1.2 + mix(capTint, vec3(1.0), 0.6) * beam.x) * (0.5 + 0.5 * step(0.02, level)) * 0.8;
        }
    }

    {
        float seam = exp(-sq((uv.y - base) * 120.0));
        float pulse = 0.35 + 0.5 * beatPulse + 0.5 * kick;
        col += mix(u.c1.rgb, vec3(1.0), 0.35) * seam * pulse * smoothstep(0.02, 0.1, uv.x) * smoothstep(0.98, 0.9, uv.x);
    }

    {
        float sweepY = base - (1.0 - snare) * usable * 1.1;
        float band = exp(-sq((uv.y - sweepY) * 26.0)) * snare * step(uv.y, base);
        float covered = smoothstep(0.0, 0.2, dot(col, vec3(0.33)));
        col += mix(u.c2.rgb, vec3(1.0), 0.5) * band * 0.3 * covered;
    }

    col = fxFlash(col, 0.2);
    col = fxTonemap(col, 1.5);
    col = fxVignette(col, p, 0.08);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
