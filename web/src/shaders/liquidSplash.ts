import type { VisualizerPort } from "./port.js";

/**
 * Iridescent liquid filaments and droplets splashing out of a core: bass sets the reach, highs the spray.
 * Ported from Sources/NardukSoundVisuals/Intense/LiquidSplash/LiquidSplashShader.swift.
 */
export const liquidSplash: VisualizerPort = {
  id: "liquidSplash",
  title: "Liquid splash",
  metalSource: "Sources/NardukSoundVisuals/Intense/LiquidSplash/LiquidSplashShader.swift",
  metalSha256: "4f1fd3b48ac0a93fbe4583dcbd96bb0aa36a207fc85c39dc01112ac6c9d66e28",
  glsl: `
// The filament field at a point: the swirled, warped position sampled on a cylinder so the strands stream
// outward from the core. Returns the raw noise (filaments sit where it crosses 0.5).
float splashField(vec2 p, float travel, float t, float warp, float swirl, float scale) {
    float r = length(p) + 1e-4;
    float a = atan(p.y, p.x) + swirl * r;
    vec2 q = vec2(cos(a), sin(a)) * r;
    vec2 w = vec2(fbm(q * 1.6 + vec2(t * 0.09, -t * 0.06)), fbm(q * 1.6 + vec2(4.7 - t * 0.07, 2.3 + t * 0.05)));
    q += (w - 0.5) * warp;
    return fxFbm3(fxCylinder(q, scale, travel, 0.35), 3);
}

// One layer of droplets in a space that zooms out of the core ('fxZoomLayer'), so every droplet flies
// outward and grows as it nears the viewer, then fades as the layer wraps; two layers half a cycle apart
// make the flight continuous. Each droplet wobbles on its own sine and is shaded as a ball.
vec3 splashDroplets(
    vec2 p, float cs, float zoom, float seed, float density, float highs, float kick, float time,
    vec3 light) {
    FxZoomLayer layer = fxZoomLayer(p, zoom);
    vec2 c;
    float h;
    if (!fxCell(layer.q, cs, seed, density, c, h)) return vec3(0.0);
    float h3 = hash21(floor(layer.q / cs) * 0.61 + seed + 9.7);
    c += cs * 0.08 * vec2(sin(time * 1.7 + h * 6.28), cos(time * 1.3 + h3 * 6.28));
    float screenDistance = length(c) * layer.scale;
    float radius = cs * (0.09 + 0.16 * h3) * (0.75 + 0.5 * highs) * (1.0 + 0.25 * kick);
    float reach = smoothstep(0.1, 0.3, screenDistance) * smoothstep(1.7, 1.1, screenDistance);
    vec3 tint = paletteAt(atan(c.y, c.x) / 6.28318 + 0.5 + 0.06 * h);
    return fxBall((layer.q - c) / radius, light, tint) * layer.fade * reach;
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float intensity = u.extra.z;
    float time = u.resTime.z * intensity;
    float travel = u.misc.z * intensity;
    float kick = u.env.x;
    float snare = u.env.y;
    float hat = u.env.z;
    float energy = u.wobble.z;
    float drop = u.misc.y;
    float bass = bandAt(0.05);
    float mids = bandAt(0.4);
    float highs = bandAt(0.8);

    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    p += u.fx.zw * 0.04 * intensity;
    p *= 1.0 - 0.05 * kick * intensity;
    float r = length(p);
    float a = atan(p.y, p.x);

    // The splash: two coarse and fine filament fields, each lit from a finite-difference normal.
    float warp = (0.25 + 0.35 * mids + 0.2 * energy) * (0.5 + 0.5 * intensity);
    float swirl = (0.08 + 0.45 * drop) * intensity;
    float reach = 0.55 + 0.6 * bass + 0.35 * drop + 0.15 * energy;
    float envelope = smoothstep(reach + 0.45, reach * 0.45, r) * smoothstep(0.0, 0.1, r);
    float arms = 0.25 + 0.75 * pow(0.5 + 0.5 * cos(a * 3.0 - travel * 0.1), 1.0);
    vec3 light = fxKeyLight();
    vec3 col = vec3(0.0);
    float hueBase = a / 6.28318 + 0.5 + travel * 0.008;
    for (int layer = 0; layer < 2; layer++) {
        float scale = layer == 0 ? 2.3 : 5.1;
        float e = layer == 0 ? 0.012 : 0.007;
        float f0 = splashField(p, travel, time, warp, swirl, scale);
        float fx = splashField(p + vec2(e, 0.0), travel, time, warp, swirl, scale);
        float fy = splashField(p + vec2(0.0, e), travel, time, warp, swirl, scale);
        float thin = layer == 0 ? 0.80 - 0.08 * energy : 0.88 - 0.05 * energy;
        float strand = fxRidge(f0, thin);
        vec3 n = fxNormal(f0, fx, fy, e, layer == 0 ? 5.0 : 8.0);
        vec2 shade = fxLight(n, light, 28.0);
        vec3 tint = paletteAt(hueBase + 0.14 * n.x + 0.1 * (f0 - 0.5) + float(layer) * 0.05);
        float weight = layer == 0 ? 1.0 : 0.6;
        float lit = strand * envelope * arms * weight * (0.8 + 0.5 * energy + 0.4 * kick);
        col += tint * shade.x * lit * 1.6 + vec3(1.0) * shade.y * lit * 1.1;
    }
    // Haze between the strands: a dim wash of the field so the splash reads as a body of liquid.
    float haze = splashField(p * 0.8, travel, time, warp, swirl, 1.4);
    col += paletteAt(hueBase + 0.3) * haze * haze * haze * envelope * arms * 0.1;

    // Droplets: big slow spheres, then fine spray that thickens with the highs and the hats.
    float density = 0.42 + 0.3 * highs + 0.2 * hat;
    for (int k = 0; k < 2; k++) {
        float offset = float(k) * 0.5;
        col += splashDroplets(p, 0.3, fract(travel * 0.09 + offset), 1.0 + offset, 0.5, highs, kick, time, light);
        col += splashDroplets(p, 0.17, fract(travel * 0.14 + 0.25 + offset), 7.0 + offset, 0.45 + 0.2 * energy, highs, kick, time, light);
        col += splashDroplets(p, 0.08, fract(travel * 0.22 + 0.1 + offset), 13.0 + offset, density, highs, kick, time, light) * 0.9;
    }

    // Snare: a ring of light runs outward through the splash.
    float ringR = 0.12 + (1.0 - snare) * 1.2;
    float ring = exp(-sq((r - ringR) * 9.0)) * snare;
    col += mix(u.c2.rgb, vec3(1.0), 0.45) * ring * 0.45 * (0.5 + envelope);

    // The core where the streams meet, breathing with the bass and jumping on the kick.
    float core = exp(-r * r * 11.0) * (0.12 + 0.5 * bass + 0.4 * kick);
    col += mix(u.c1.rgb, vec3(1.0), 0.6) * core;
    col += mix(u.c0.rgb, u.c2.rgb, 0.5) * exp(-r * r * 2.5) * 0.06 * (0.5 + energy);

    col = fxFlash(col, 0.3);
    col = fxTonemap(col, 1.4);
    col = fxVignette(col, p, 0.09);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
