import type { VisualizerPort } from "./port.js";

/**
 * Hyperspace + lasers: warp-speed star streaks with chromatic aberration, and laser beams through volumetric fog
 * that sweep on the beat and strobe on the snare (the strobe is the already rationed `extra.x`).
 * Ported from Sources/NardukSoundVisuals/Intense/Hyperspace/HyperspaceShader.swift.
 */
export const hyperspaceLasers: VisualizerPort = {
  id: "hyperspaceLasers",
  title: "Hyperspace + lasers",
  metalSource: "Sources/NardukSoundVisuals/Intense/Hyperspace/HyperspaceShader.swift",
  metalSha256: "292aef93bf567faeffdf9b0a64ee9b0101019ce4461dbee2731b581b445a356f",
  glsl: `
// One layer of star streaks. Stars sit in angular cells; each star's radius runs 0 -> rim and accelerates
// (pow), and its streak trails behind it, longer when the drop stretches the warp.
float streakLayer(vec2 p, float travel, float speed, float count, float seed, float stretch, float px) {
    float r = length(p);
    float a = atan(p.y, p.x) / 6.28318 + 0.5;
    float cell = a * count;
    float id = floor(cell);
    float ang = fract(cell) - 0.5;
    float h = hash11(id + seed);
    float h2 = hash11(id * 1.37 + seed + 9.1);
    float off = (h - 0.5) * 0.6;
    float s = fract(h2 + travel * speed * (0.6 + 0.8 * h));
    float rad = pow(s, 1.7) * 1.6;
    float len = (0.25 + 1.0 * stretch) * rad + 0.01;
    float dAng = (ang - off) * 6.28318 * max(r, 0.03);
    float w = px * 1.6 + 0.0012 * (1.0 + 2.0 * rad);
    float lateral = exp(-(dAng * dAng) / (w * w));
    float radial = smoothstep(rad - len, rad, r) * (1.0 - smoothstep(rad, rad + 0.012, r));
    float fade = smoothstep(0.0, 0.18, s);
    return lateral * radial * fade * (0.8 + 1.6 * s);
}

vec3 stars(vec2 p, float scale, float stretch, float px) {
    float travel = u.misc.z;
    vec3 col = vec3(0.0);
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        vec3 tint = mix(paletteAt(fl * 0.27 + 0.05), vec3(1.0), 0.55);
        float v = streakLayer(p * scale, travel, 0.55 + 0.3 * fl, 70.0 + 38.0 * fl, fl * 31.7, stretch, px);
        col += tint * v;
    }
    return col;
}

// The laser rig: beams from the top and bottom edges, each sweeping on its own beat multiple, lit by fog
// that drifts. Calm narrows the sweep.
vec3 lasers(vec2 p, float fog) {
    float beats = u.resTime.w;
    float kick = u.env.x;
    float drop = u.misc.y;
    float strobe = u.extra.x;
    float intensity = u.extra.z;
    int count = 5 + int(round(4.0 * drop));
    vec3 col = vec3(0.0);
    for (int i = 0; i < 9; i++) {
        if (i >= count) break;
        float fi = float(i);
        bool top = (i % 2) == 0;
        vec2 src = vec2(mix(-1.5, 1.5, (fi + 0.5) / 9.0), top ? 1.15 : -1.15);
        float ang = sin(beats * (0.5 + 0.13 * fi) + fi * 1.7) * 0.95 * intensity;
        vec2 d = vec2(sin(ang), cos(ang) * (top ? -1.0 : 1.0));
        vec2 rel = p - src;
        float along = dot(rel, d);
        float dist = abs(rel.x * d.y - rel.y * d.x);
        float width = 0.010 + 0.02 * kick;
        float core = exp(-(dist * dist) / (width * width));
        float glow = exp(-dist * 5.0) * 0.28;
        float atten = smoothstep(0.0, 0.25, along) * exp(-along * 0.32);
        float scatter = glow * (0.45 + 1.1 * fog);
        float beam = (core * 1.5 + scatter) * atten * (0.5 + 1.2 * strobe);
        vec3 tint = paletteAt(fi / 9.0 + beats / 32.0);
        col += mix(tint, vec3(1.0), core * 0.6) * beam;
    }
    return col * (0.55 + 0.7 * drop);
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float time = u.resTime.z;
    float kick = u.env.x;
    float energy = u.wobble.z;
    float drop = u.misc.y;
    float intensity = u.extra.z;
    float px = 2.0 / u.resTime.y;

    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    p += u.fx.zw * 0.04 * intensity;
    p *= 1.0 - 0.05 * kick * intensity;

    // Chromatic aberration: the streaks are drawn three times at slightly different scales.
    float ca = (0.006 + 0.05 * u.fx.y + 0.02 * energy) * intensity;
    float stretch = (0.45 + 0.55 * drop) * (0.4 + 0.6 * intensity);
    vec3 sr = stars(p, 1.0 + ca, stretch, px);
    vec3 sg = stars(p, 1.0, stretch, px);
    vec3 sb = stars(p, 1.0 - ca, stretch, px);
    vec3 col = vec3(sr.r, sg.g, sb.b) * (0.9 + 0.5 * energy);

    float fog = fbm(p * 1.6 + vec2(time * 0.04, -time * 0.025));
    vec3 bg = (u.c0.rgb * 0.05 + u.c1.rgb * 0.035 * fog) * (0.6 + 0.8 * length(p) * 0.3);
    col += bg + lasers(p, fog);

    // A soft core where the warp converges, breathing with the bass.
    float core = exp(-dot(p, p) * 9.0) * (0.12 + 0.35 * bandAt(0.05) + 0.25 * kick);
    col += mix(u.c1.rgb, vec3(1.0), 0.5) * core;

    // The rationed flash: already limited on the CPU, tinted red-safe.
    col += u.flashColor.rgb * u.extra.x * 0.32;

    col = 1.0 - exp(-col * 1.35);
    col *= 1.0 - 0.28 * dot(p, p) * 0.35;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
