import type { VisualizerPort } from "./port.js";

/**
 * Halo: a radial spectrum around a glossy, breathing core. The 64 bands fan out as lit needles on both sides of a
 * slowly turning axis, with peak-hold ticks and an envelope bloom; the core is a shaded ball with a plasma skin and
 * the waveform wraps inside it as a neon ring; beat rings, dust and sparks fly outward.
 * Ported from Sources/NardukSoundVisuals/Intense/HaloMetal/HaloMetalShader.swift.
 */
export const halo: VisualizerPort = {
  id: "halo",
  title: "Halo",
  metalSource: "Sources/NardukSoundVisuals/Intense/HaloMetal/HaloMetalShader.swift",
  metalSha256: "6728652a3f0387da34e6c61427b6b623f616a837b44221564ed7cfc22b8cfb9c",
  glsl: `
float haloMetalWrap(float a) {
    return a - 6.2831853 * floor(a / 6.2831853 + 0.5);
}

vec3 haloMetalDust(vec2 p, float zoom, float seed, float density, float time, vec3 tint) {
    FxZoomLayer layer = fxZoomLayer(p, zoom);
    vec2 c;
    float h;
    if (!fxCell(layer.q, 0.16, seed, density, c, h)) return vec3(0.0);
    c += 0.02 * vec2(sin(time * 1.3 + h * 6.28), cos(time * 1.1 + h * 9.0));
    float screenDistance = length(c) * layer.scale;
    float reach = smoothstep(0.2, 0.5, screenDistance) * smoothstep(1.8, 1.2, screenDistance);
    vec2 rel = layer.q - c;
    float spark = exp(-dot(rel, rel) * 11000.0 / (0.5 + h));
    return tint * spark * layer.fade * reach;
}

float haloWaveAtTurn(float turn) {
    return waveAt(int(turn * 511.0));
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
    float beatPhase = fract(beats);
    float beatPulse = pow(1.0 - beatPhase, 3.0);

    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    p += u.fx.zw * 0.03 * intensity;
    float r = length(p) + 1e-4;
    float a = atan(p.y, p.x);
    vec3 light = fxKeyLight();

    float pulse = 1.0 + 0.12 * kick * intensity + 0.03 * beatPulse + 0.07 * bass * intensity;
    float coreR = 0.30 * pulse;
    float inner = coreR + 0.04;
    float maxLength = 0.46 * (1.0 + 0.25 * drop);
    float rotation = beats / 16.0 * 6.2831853 - 1.5707963;
    vec3 col = vec3(0.002, 0.004, 0.012) + mix(u.c0.rgb, u.c1.rgb, 0.5) * exp(-r * r * 1.6) * (0.03 + 0.05 * energy + 0.07 * kick);

    col += mix(vec3(0.7, 0.8, 1.0), u.c2.rgb, 0.4) * fxStars(p, 15.0, 4.0, time) * 0.5;
    vec3 dustTint = mix(u.c1.rgb, vec3(1.0), 0.5) * (0.5 + 0.9 * highs + 0.5 * hat);
    col += haloMetalDust(p, fract(travel * 0.08), 3.0, 0.3, time, dustTint) * 0.6;
    col += haloMetalDust(p, fract(travel * 0.08 + 0.5), 3.5, 0.3, time, dustTint) * 0.6;

    for (int k = 0; k < 4; k++) {
        float age = (beatPhase + float(k)) / 4.0;
        float ringR = inner + age * maxLength * 1.5;
        col += u.c2.rgb * exp(-sq((r - ringR) * 90.0)) * (1.0 - age) * (1.0 - age) * 0.28;
    }
    float shockR = inner + (1.0 - snare) * 1.3;
    col += mix(u.c1.rgb, vec3(1.0), 0.4) * exp(-sq((r - shockR) / (0.012 + 0.04 * snare))) * snare * 0.7;

    float spread = abs(haloMetalWrap(a - rotation));
    float bandPos = spread / 3.1415927 * 64.0;
    int i = clamp(int(bandPos), 0, 63);
    float f = fract(bandPos);
    float v = pow(spectrumAt(i), 0.8);
    float length_ = max(0.012, v * maxLength);
    float lateral = (f - 0.5) * 3.1415927 / 64.0 * r;
    float s = (r - inner) / length_;
    float halfW = 0.0052 + 0.0032 * clamp(s, 0.0, 1.0);
    vec3 hue = paletteAt(spread / 3.1415927 * 0.66);
    {
        float lx = lateral / halfW;
        float tipEnd = inner + length_;
        float dTip = max(r - tipEnd, 0.0);
        float outside = max(abs(lateral) - halfW * (1.0 - 0.35 * pow(clamp(s, 0.0, 1.0), 3.0)), 0.0);
        if (r > inner * 0.98) {
            float inside = step(r, tipEnd) * smoothstep(1.1, 0.75, abs(lx));
            float z = sqrt(max(1.0 - lx * lx, 0.0));
            vec2 lit = fxLight(vec3(lx, 0.0, z), light, 22.0);
            vec3 body = mix(hue * 0.5, mix(hue, vec3(1.0), 0.45), clamp(s, 0.0, 1.0)) * (0.3 + 0.9 * lit.x);
            col += (body * 1.5 + vec3(1.0) * lit.y * 0.5) * inside * (0.5 + 0.8 * v);
            vec2 beam = fxBeam(length(vec2(outside, dTip)), 0.005);
            col += (hue * beam.y * 1.5 + mix(hue, vec3(1.0), 0.7) * beam.x * 0.8) * (0.4 + 1.1 * v);
            float peakEnd = inner + pow(auxAt(i), 0.8) * maxLength + 0.018;
            float tick = exp(-sq((r - peakEnd) * 200.0)) * smoothstep(1.2, 0.5, abs(lx)) * step(0.01, auxAt(i));
            col += vec3(1.0) * tick * 0.8;
        }
        float env = pow(bandAt(clamp(bandPos / 64.0, 0.0, 1.0)), 0.8);
        float envEnd = inner + env * maxLength;
        col += hue * exp(-max(r - envEnd, 0.0) * 8.0) * smoothstep(inner * 0.9, inner * 1.3, r) * env * 0.14 * (1.0 + 0.8 * kick);
    }

    {
        float cellA = floor(spread / 3.1415927 * 24.0 + 0.5);
        float shed = hash21(vec2(cellA, floor(travel * 1.3 + hash11(cellA) * 4.0)));
        float t = fract(travel * 1.3 + hash11(cellA) * 4.0);
        float lenA = pow(spectrumAt(clamp(int(cellA / 24.0 * 63.0), 0, 63)), 0.8) * maxLength;
        float sparkR = inner + lenA + t * 0.22;
        float sparkA = rotation + (shed > 0.5 ? 1.0 : -1.0) * cellA / 24.0 * 3.1415927;
        vec2 sc = vec2(cos(sparkA), sin(sparkA)) * sparkR;
        float on = step(0.55 - 0.3 * highs - 0.2 * hat, hash11(cellA * 1.7 + floor(travel * 1.3) * 3.1));
        col += mix(u.c2.rgb, vec3(1.0), 0.7) * exp(-dot(p - sc, p - sc) * 9000.0) * (1.0 - t) * on * 0.9;
    }

    {
        vec2 rel = p / coreR;
        float d2 = dot(rel, rel);
        if (d2 < 1.2) {
            float z = sqrt(max(1.0 - d2, 0.0));
            vec3 n = vec3(rel, z);
            vec2 lit = fxLight(n, light, 20.0);
            float plasma = fxFbm3(vec3(rel * 2.2 + vec2(cos(time * 0.2), sin(time * 0.2)) * 0.6, time * 0.25), 3);
            vec3 tint = mix(u.c1.rgb, u.c0.rgb, plasma);
            vec3 skin = tint * (0.08 + 0.55 * lit.x) * (0.35 + 1.5 * plasma * plasma) + vec3(1.0) * lit.y * 0.55;
            skin += mix(tint, vec3(1.0), 0.6) * (0.2 * kick + 0.05 * energy + 0.3 * bass) * z;
            float rim = smoothstep(0.6, 1.0, sqrt(d2));
            skin += u.c2.rgb * rim * (0.5 + 0.5 * energy);
            col = mix(col, skin, smoothstep(1.02, 0.94, sqrt(d2)));
        }
        col += mix(u.c1.rgb, u.c0.rgb, 0.5) * exp(-max(r - coreR, 0.0) * 14.0) * 0.12 * (0.6 + 0.6 * kick + 0.8 * bass);

        float turn = fract((a - rotation) / 6.2831853);
        float w = haloWaveAtTurn(turn);
        float ringR = coreR * (0.78 + 0.32 * w * 0.8);
        vec2 beam = fxBeam(abs(r - ringR), 0.004);
        float chroma = u.fx.y;
        vec3 ringTint = mix(u.c2.rgb, vec3(1.0), 0.75);
        col += (u.c2.rgb * beam.y * 1.3 + ringTint * beam.x) * smoothstep(coreR * 1.08, coreR * 0.9, r);
        if (chroma > 0.02) {
            vec2 pl = p - vec2(chroma * 0.02, 0.0);
            vec2 pr = p + vec2(chroma * 0.02, 0.0);
            float wl = haloWaveAtTurn(fract((atan(pl.y, pl.x) - rotation) / 6.2831853));
            float wr = haloWaveAtTurn(fract((atan(pr.y, pr.x) - rotation) / 6.2831853));
            col += u.c0.rgb * fxBeam(abs(length(pl) - coreR * (0.78 + 0.26 * wl)), 0.004).x * 0.6;
            col += u.c2.rgb * fxBeam(abs(length(pr) - coreR * (0.78 + 0.26 * wr)), 0.004).x * 0.6;
        }
    }

    col = fxFlash(col, 0.25);
    col = fxTonemap(col, 1.3);
    col = fxVignette(col, p, 0.1);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
