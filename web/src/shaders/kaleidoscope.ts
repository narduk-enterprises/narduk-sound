import type { VisualizerPort } from "./port.js";

/**
 * Beat kaleidoscope: a beat tunnel seen through a kaleidoscope. Rings rush out of the centre on the beat clock and
 * the 64-band spectrum folds into mirrored petals around them, six folds at rest and eight in a drop.
 * Ported from Sources/NardukSoundVisuals/Intense/KaleidoscopeMetal/KaleidoscopeMetalShader.swift.
 */
export const kaleidoscope: VisualizerPort = {
  id: "kaleidoscope",
  title: "Beat kaleidoscope",
  metalSource: "Sources/NardukSoundVisuals/Intense/KaleidoscopeMetal/KaleidoscopeMetalShader.swift",
  metalSha256: "67a5b1c72bc270af91b029e3cb7f1d88223734e3b18896a98e7a6a4c86f57ecd",
  glsl: `
// The folded spectrum's reach at angle 'a' (radians, already spun): the petal's radius, or -1 between petals.
float kaleidoscopeMetalReach(float a, float wedge) {
    float period = wedge * 2.0;
    float m = a - floor(a / period) * period;
    if (m >= wedge) return -1.0;
    float s = m / wedge;
    float t = 1.0 - abs(2.0 * s - 1.0);
    return 0.14 + 0.7 * bandAt(t);
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float intensity = u.extra.z;
    float time = u.resTime.z;
    float kick = u.env.x;
    float energy = u.wobble.z;
    float wild = u.misc.x;
    float drop = u.misc.y;
    float travel = fract(u.misc.z);
    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    float r = length(p);
    vec3 col = vec3(0.0);

    // The tunnel: nine rings, each born at the center and growing to the edge.
    for (int i = 0; i < 9; i++) {
        float phase = (float(i) + travel) / 9.0;
        float radius = 1.15 * phase * phase;
        float width = max(0.004, 0.01 * (0.4 + phase));
        float pulse = min(1.0 + kick * 0.6 * (1.0 - phase), 1.4);
        float alpha = (0.15 + 0.6 * phase) * pulse;
        col += paletteAt(phase * 0.5 + 0.1) * alpha * smoothstep(width * 1.4, width * 0.3, abs(r - radius));
    }

    // The fold: petals of mirrored spectrum. Calm (intensity below 1) holds the spin still.
    float folds = drop > 0.5 ? 8.0 : 6.0;
    float wedge = 6.2831853 / folds;
    float spin = intensity < 1.0 ? 0.0 : time * 0.12 * (0.5 + wild);
    float a = atan(p.y, p.x) - spin;
    float reach = kaleidoscopeMetalReach(a, wedge);
    if (reach > 0.0) {
        float e = 0.01;
        float ahead = kaleidoscopeMetalReach(a + e, wedge);
        float behind = kaleidoscopeMetalReach(a - e, wedge);
        float slope = (ahead > 0.0 && behind > 0.0) ? (ahead - behind) / (2.0 * e * max(r, 0.05)) : 0.0;
        float d = abs(r - reach) / sqrt(1.0 + slope * slope);
        float period = wedge * 2.0;
        float pair = floor(a / period);
        float fold = 2.0 * pair + (a - pair * period >= wedge * 0.5 ? 1.0 : 0.0);
        float tint = fold / folds + u.misc.w * 0.1;
        col += paletteAt(tint) * (0.55 + 0.4 * energy) * smoothstep(0.016, 0.003, d);
    }
    col = fxTonemap(col, 1.3);
    col = fxFlash(col, 0.1);
    fragColor = vec4(col, 1.0);
}
`,
};
