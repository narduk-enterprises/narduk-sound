/**
 * The GLSL ES 3.00 twin of IntenseShaderCommon.swift and IntenseEffects.swift: the uniform block, the full-screen
 * vertex, hashes, noise, the palette ramp and the `fx` effects library. Every helper keeps its Metal name and math so
 * a visualizer body ports almost line for line (docs/web-port.md has the translation table).
 */

/** The full-screen triangle; `vUv` is (0, 0) at the top left, as Metal's `in.uv` is. */
export const VERTEX_SHADER = `#version 300 es
out vec2 vUv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    vUv = vec2(p.x, 1.0 - p.y);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`;

/** Everything before a visualizer's own GLSL. */
export const FRAGMENT_PRELUDE = `#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;

// Must match IntenseUniforms in IntenseRenderer.swift (10 x float4) and UNIFORM_NAMES in uniforms.ts.
struct IntenseUniforms {
    vec4 resTime;    // width, height, time (s), beats
    vec4 env;        // kick, snare, hat, impact
    vec4 wobble;     // cutoff, phase, energy, glitch
    vec4 fx;         // flash (unused here), chroma, shakeX, shakeY
    vec4 misc;       // wild, dropAmount, travel, barPhase
    vec4 c0;
    vec4 c1;
    vec4 c2;
    vec4 extra;      // limited flash, look active, intensity (1, or less in calm), glitch amount
    vec4 flashColor; // red-safe flash tint, a = 1 in calm
};
uniform IntenseUniforms u;

// The Metal fragment buffers, as rows of one R32F texture (uniforms.ts: DataRow).
uniform sampler2D uData;

in vec2 vUv;
out vec4 fragColor;

float spectrumAt(int i) { return texelFetch(uData, ivec2(clamp(i, 0, 63), 0), 0).r; }
float waveAt(int i) { return texelFetch(uData, ivec2(clamp(i, 0, 511), 1), 0).r; }
float auxAt(int i) { return texelFetch(uData, ivec2(clamp(i, 0, 127), 2), 0).r; }
float historyAt(int i) {
    int k = clamp(i, 0, 767);
    return texelFetch(uData, ivec2(k % 512, 3 + k / 512), 0).r;
}

// Metal's fmod: the remainder takes the sign of x. GLSL mod() floors, so it differs below zero.
float mslFmod(float x, float y) { return x - y * trunc(x / y); }

// pow(x, 2.0) is undefined for x < 0 in GLSL (and in Metal fast math); a port squares explicitly.
float sq(float x) { return x * x; }

float hash11(float x) {
    x = fract(x * 0.1031);
    x *= x + 33.33;
    x *= x + x;
    return fract(x);
}

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
               mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + vec2(17.1, 9.2);
        a *= 0.5;
    }
    return v;
}

float bandAt(float x) {
    float f = clamp(x, 0.0, 1.0) * 63.0;
    int i = int(f);
    int j = min(i + 1, 63);
    return mix(spectrumAt(i), spectrumAt(j), fract(f));
}

vec3 paletteAt(float t) {
    float f = fract(t) * 3.0;
    float s = fract(f);
    s = s * s * (3.0 - 2.0 * s);
    if (f < 1.0) return mix(u.c0.rgb, u.c1.rgb, s);
    if (f < 2.0) return mix(u.c1.rgb, u.c2.rgb, s);
    return mix(u.c2.rgb, u.c0.rgb, s);
}

// ---- IntenseEffects ----------------------------------------------------------------------------------------

float fxHash31(vec3 p) {
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float fxNoise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = fxHash31(i);
    float n100 = fxHash31(i + vec3(1, 0, 0));
    float n010 = fxHash31(i + vec3(0, 1, 0));
    float n110 = fxHash31(i + vec3(1, 1, 0));
    float n001 = fxHash31(i + vec3(0, 0, 1));
    float n101 = fxHash31(i + vec3(1, 0, 1));
    float n011 = fxHash31(i + vec3(0, 1, 1));
    float n111 = fxHash31(i + vec3(1, 1, 1));
    float x00 = mix(n000, n100, f.x);
    float x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x);
    float x11 = mix(n011, n111, f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

float fxFbm3(vec3 p, int octaves) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        if (i >= octaves) break;
        v += a * fxNoise3(p);
        p = p * 2.07 + vec3(11.3, 7.9, 3.1);
        a *= 0.5;
    }
    return v;
}

vec3 fxCylinder(vec2 p, float scale, float travel, float stream) {
    float r = length(p) + 1e-4;
    vec2 dir = p / r;
    return vec3(dir * scale * 1.5, r * scale * 0.55 - travel * stream);
}

float fxRidge(float f, float thin) {
    float ridge = 1.0 - abs(f * 2.0 - 1.0);
    return pow(smoothstep(thin, 1.0, ridge), 2.2);
}

vec3 fxNormal(float f0, float fx, float fy, float e, float relief) {
    return normalize(vec3(-(fx - f0) / e, -(fy - f0) / e, relief));
}

vec2 fxLight(vec3 n, vec3 light, float shininess) {
    float diff = 0.35 + 0.65 * max(dot(n, light), 0.0);
    float spec = pow(max(dot(reflect(-light, n), vec3(0.0, 0.0, 1.0)), 0.0), shininess);
    return vec2(diff, spec);
}

vec3 fxKeyLight() {
    return normalize(vec3(-0.45, 0.55, 0.7));
}

vec3 fxBall(vec2 rel, vec3 light, vec3 tint) {
    float d2 = dot(rel, rel);
    if (d2 > 1.0) return vec3(0.0);
    float d = sqrt(d2);
    float z = sqrt(max(1.0 - d2, 0.0));
    vec3 n = vec3(rel, z);
    vec2 lit = fxLight(n, light, 24.0);
    float diff = 0.25 + 0.75 * max(dot(n, light), 0.0);
    float rim = smoothstep(0.55, 1.0, d);
    float body = 1.0 - smoothstep(0.9, 1.0, d);
    vec3 col = tint * (0.12 + 0.5 * diff) * (1.0 - 0.7 * rim) + tint * rim * 1.3 + vec3(1.0) * lit.y * 1.3;
    return col * body;
}

struct FxZoomLayer {
    vec2 q;
    float scale;
    float fade;
};

FxZoomLayer fxZoomLayer(vec2 p, float zoom) {
    FxZoomLayer layer;
    layer.scale = exp2(zoom);
    layer.q = p / layer.scale;
    layer.fade = sin(zoom * 3.14159265);
    return layer;
}

bool fxCell(vec2 q, float cs, float seed, float density, out vec2 center, out float h) {
    vec2 id = floor(q / cs);
    h = hash21(id + seed);
    center = vec2(0.0);
    if (h > density) return false;
    float h2 = hash21(id * 1.73 + seed + 5.1);
    float h3 = hash21(id * 0.61 + seed + 9.7);
    center = (id + 0.5 + (vec2(h2, h3) - 0.5) * 0.5) * cs;
    return true;
}

float fxSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return length(pa - ba * h);
}

vec2 fxBeam(float d, float width) {
    float core = exp(-d * d / (width * width));
    float halo = exp(-d / (width * 3.5)) * 0.35;
    return vec2(core, halo);
}

float fxRoundBox(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float fxStars(vec2 p, float scale, float seed, float time) {
    vec2 sp = p * scale;
    vec2 id = floor(sp);
    float h = hash21(id + seed);
    vec2 c = id + 0.5 + (vec2(hash21(id + seed + 3.1), hash21(id + seed + 7.7)) - 0.5) * 0.8;
    float star = exp(-dot(sp - c, sp - c) * 60.0) * step(0.88, h) * (0.3 + 0.7 * hash21(id + seed + 1.3));
    return star * (0.5 + 0.5 * sin(time * 1.5 + h * 40.0));
}

// The only full-screen brightness jump a shader may add: the CPU-rationed flash, at most 0.35 of it.
vec3 fxFlash(vec3 col, float k) {
    return col + u.flashColor.rgb * u.extra.x * min(k, 0.35);
}

vec3 fxTonemap(vec3 col, float k) {
    return 1.0 - exp(-col * k);
}

vec3 fxVignette(vec3 col, vec2 p, float k) {
    return col * (1.0 - k * dot(p, p));
}
`;

/** Draws a finished picture scaled by the luma watchdog's gain (IntenseRenderer's `intenseDimFragment`). */
export const PRESENT_SHADER = `#version 300 es
precision highp float;
uniform sampler2D uScene;
uniform float uGain;
in vec2 vUv;
out vec4 fragColor;
void main() {
    vec4 c = texture(uScene, vec2(vUv.x, 1.0 - vUv.y));
    fragColor = vec4(c.rgb * uGain, 1.0);
}
`;
