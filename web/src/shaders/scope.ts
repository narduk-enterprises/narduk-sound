import type { VisualizerPort } from "./port.js";

/**
 * Scope: the waveform as a phosphor beam on curved CRT glass, triggered on a rising zero crossing so the trace holds
 * still, five older traces receding up the glass, a lit graticule, scanlines, a glare streak and a dark bezel.
 * Ported from Sources/NardukSoundVisuals/Intense/ScopeMetal/ScopeMetalShader.swift.
 */
export const scope: VisualizerPort = {
  id: "scope",
  title: "Scope",
  metalSource: "Sources/NardukSoundVisuals/Intense/ScopeMetal/ScopeMetalShader.swift",
  metalSha256: "82cae79b37012b7deeb0d1faedb2a65ea624e1899d4b6a6da17273af72e0317e",
  glsl: `
float scopeMetalAmp(float k, float time, float silent) {
    float i0 = clamp(floor(k), 0.0, 510.0);
    float f = clamp(k - i0, 0.0, 1.0);
    float live = mix(waveAt(int(i0)), waveAt(int(i0) + 1), f);
    float idle = 0.06 * sin(time * 2.5 + k * 0.07);
    return clamp(mix(live, idle, silent), -1.0, 1.0);
}

float scopeMetalHistory(int age, float x) {
    float k = clamp(x, 0.0, 1.0) * 127.0;
    int i = int(min(floor(k), 126.0));
    return mix(historyAt(age * 128 + i), historyAt(age * 128 + i + 1), k - float(i));
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float intensity = u.extra.z;
    float time = u.resTime.z * intensity;
    float beats = u.resTime.w;
    float kick = u.env.x;
    float snare = u.env.y;
    float hat = u.env.z;
    float energy = u.wobble.z;
    float drop = u.misc.y;
    float bass = bandAt(0.05);
    float highs = bandAt(0.8);
    float beatPulse = pow(1.0 - fract(beats), 3.0);
    float silent = auxAt(119);
    float trigger = auxAt(118);
    float px = u.resTime.y;

    vec2 q = vUv - 0.5;
    vec2 wu = 0.5 + q * (1.0 + 0.11 * dot(q, q) * 2.0);
    vec2 sp = (wu - 0.5) * vec2(aspect, 1.0);
    float sdf = fxRoundBox(sp, vec2(0.5 * aspect - 0.025, 0.465), 0.075);
    float screen = smoothstep(0.003, -0.003, sdf);
    float vig = clamp(1.0 - 0.9 * dot(q, q) * 1.6, 0.0, 1.0);

    vec3 deep = mix(u.c0.rgb, u.c1.rgb, 0.5);
    vec3 col = vec3(0.002, 0.005, 0.008) + deep * (0.07 + 0.1 * energy + 0.2 * bass + 0.1 * kick) * exp(-dot(q, q) * 3.2);
    float staticNoise = hash21(floor(vUv * vec2(u.resTime.x, u.resTime.y) * 0.5) + floor(time * 30.0));
    col += vec3(0.6, 0.8, 1.0) * staticNoise * staticNoise * staticNoise * (0.01 + 0.05 * highs + 0.03 * hat);

    float ux = (wu.x - 0.04) / 0.92;
    vec2 ps = vec2(wu.x * aspect, wu.y);
    float onScreen = step(0.0, ux) * step(ux, 1.0);

    vec2 beam = vec2(0.0);
    float beamY = 0.5;
    {
        float k = trigger + clamp(ux, 0.0, 1.0) * 383.0;
        float k0 = floor(k) - 2.0;
        float best = 1e3;
        float slow = 1.0;
        for (int j = 0; j < 5; j++) {
            float ka = k0 + float(j);
            float kb = ka + 1.0;
            vec2 a = vec2((0.04 + 0.92 * (ka - trigger) / 383.0) * aspect, 0.5 - scopeMetalAmp(ka, time, silent) * 0.4);
            vec2 b = vec2((0.04 + 0.92 * (kb - trigger) / 383.0) * aspect, 0.5 - scopeMetalAmp(kb, time, silent) * 0.4);
            float d = fxSegment(ps, a, b);
            if (d < best) {
                best = d;
                slow = 1.0 / sqrt(1.0 + 140.0 * (b.y - a.y) * (b.y - a.y) / max(1e-4, (b.x - a.x) * (b.x - a.x)) * 0.01);
            }
        }
        beamY = 0.5 - scopeMetalAmp(k, time, silent) * 0.4;
        beam = fxBeam(best, 0.0032 + 0.0014 * bass + 0.0012 * kick) * slow;
    }

    {
        float gx = abs(fract(ux * 8.0 + 0.5) - 0.5) / 8.0 * 0.92 * aspect;
        float gy = abs(fract((wu.y - 0.1) / 0.2 + 0.5) - 0.5) * 0.2;
        float lines = exp(-sq(gx * px * 0.7)) + exp(-sq(gy * px * 0.7));
        float axis = exp(-sq((wu.y - 0.5) * px * 0.7)) + exp(-sq((ux - 0.5) * 0.92 * aspect * px * 0.7));
        float tickMark = exp(-sq(abs(fract(ux * 40.0 + 0.5) - 0.5) / 40.0 * 0.92 * aspect * px * 0.9)) * smoothstep(0.014, 0.0, abs(wu.y - 0.5)) * 1.6;
        float nearBeam = 1.0 + 4.0 * exp(-abs(wu.y - beamY) * 14.0) * (0.4 + 0.6 * energy);
        float edge = 0.4 + 1.8 * highs * smoothstep(0.2, 0.5, abs(ux - 0.5));
        vec3 grid = mix(u.c0.rgb, u.c1.rgb, 0.7) * (lines * 0.16 + axis * (0.1 + 0.2 * beatPulse) + tickMark * 0.22);
        col += grid * nearBeam * edge * onScreen * (0.8 + 0.6 * kick);
    }

    for (int age = 1; age < 6; age++) {
        float depth = float(age) / 5.0;
        float scaleX = 1.0 - 0.09 * float(age);
        float hx = (ux - 0.5) / scaleX + 0.5;
        if (hx < 0.0 || hx > 1.0) continue;
        float centerY = 0.5 - 0.075 * float(age) * (1.0 + 0.0 * drop);
        float height = 0.4 * (1.0 - 0.13 * float(age));
        float yv = centerY - scopeMetalHistory(age, hx) * height;
        float yl = centerY - scopeMetalHistory(age, hx - 0.01) * height;
        float yr = centerY - scopeMetalHistory(age, hx + 0.01) * height;
        float slope = (yr - yl) / (0.02 * scaleX * 0.92 * aspect);
        float d = abs(wu.y - yv) / sqrt(1.0 + slope * slope);
        vec2 trace = fxBeam(d, 0.0026 * (1.0 - 0.3 * depth));
        vec3 tint = mix(u.c1.rgb, u.c0.rgb, depth);
        float fade = 1.5 * pow(0.66, float(age)) * (hx > 0.0 ? 1.0 : 0.0);
        float haveHistory = step(1e-4, abs(scopeMetalHistory(age, 0.5)) + abs(scopeMetalHistory(age, 0.1)));
        col += tint * (trace.x * 0.8 + trace.y * 0.7) * fade * onScreen * mix(0.15, 1.0, haveHistory);
    }

    vec3 hot = mix(u.c1.rgb, vec3(1.0), 0.55);
    float flare = 1.0 + 1.1 * kick + 0.5 * beatPulse * energy;
    col += (hot * beam.x * 2.2 + u.c1.rgb * beam.y * (1.3 + 2.4 * bass)) * flare * onScreen;
    float spark = hash21(floor(vec2(ux * 480.0, time * 20.0)));
    col += u.c2.rgb * beam.x * step(0.82, spark) * (0.1 + 1.6 * highs * highs) * onScreen;
    col += u.c1.rgb * exp(-abs(wu.y - beamY) * 7.0) * 0.05 * (0.4 + 1.8 * bass) * onScreen;

    float bar = exp(-sq((ux - (1.0 - snare)) * 24.0)) * smoothstep(0.02, 0.2, snare);
    col += mix(u.c2.rgb, vec3(1.0), 0.4) * bar * (0.1 + 0.25 * snare) * smoothstep(0.55, 0.0, abs(wu.y - 0.5)) * onScreen;

    col *= 0.86 + 0.14 * sin(vUv.y * px * 3.14159);
    float glare = exp(-sq(dot(wu - vec2(0.18, 0.12), normalize(vec2(0.7, 0.7))) * 9.0)) * smoothstep(0.65, 0.1, wu.x + wu.y * 0.6);
    col += vec3(0.8, 0.9, 1.0) * glare * 0.07;
    col *= vig;
    col *= screen;

    float lip = exp(-sq(sdf * px * 0.4)) * 0.07 * (0.5 + 0.5 * energy);
    col += mix(vec3(0.01, 0.012, 0.016), deep * 0.4, lip * 12.0) * (1.0 - screen) * (0.4 + 0.6 * exp(-max(sdf, 0.0) * 18.0));

    col = fxFlash(col, 0.2);
    col = fxTonemap(col, 1.35);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
