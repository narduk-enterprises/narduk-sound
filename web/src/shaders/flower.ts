import type { VisualizerPort } from "./port.js";

/**
 * Luminous 3-D glass blossoms in a night garden: the beat opens them, the spectrum lights their veins.
 * Ported from Sources/NardukSoundVisuals/Intense/Flower/FlowerShader.swift.
 */
export const flower: VisualizerPort = {
  id: "flower",
  title: "Flower",
  metalSource: "Sources/NardukSoundVisuals/Intense/Flower/FlowerShader.swift",
  metalSha256: "91d90d5161b4edf526b08a27f881694d36b968d0bc4790bbbfe0194e8ee2efe4",
  glsl: `
const int kFlowers = 4;
// Per flower: size, depth, home (x, y), bloom rate (strokes per beat), bloom offset (beats).
const float kFlowerSize[4] = float[4](0.62, 0.36, 0.3, 0.42);
const float kFlowerDepth[4] = float[4](0.2, -1.4, -2.6, -0.5);
const float kFlowerHome[4] = float[4](0.05, -1.35, 1.6, 1.15);
const float kFlowerHomeY[4] = float[4](-0.25, 0.1, 0.55, -0.55);
const float kFlowerRate[4] = float[4](1.0, 0.5, 0.5, 1.0);
const float kFlowerOffset[4] = float[4](0.0, 1.0, 0.0, 0.5);
// Per petal ring: petal count, length and width (in flower sizes), closed and open angle from the axis.
const int kRingCount[3] = int[3](5, 8, 11);
const float kRingLength[3] = float[3](0.5, 0.74, 0.96);
const float kRingWidth[3] = float[3](0.24, 0.3, 0.33);
const float kRingClosed[3] = float[3](0.22, 0.32, 0.45);
const float kRingOpen[3] = float[3](0.75, 1.1, 1.42);

struct FlowerCamera {
    vec3 ro;
    vec3 fw;
    vec3 rt;
    vec3 up;
    float fl;
};

vec3 flowerProject(in FlowerCamera cam, vec3 w) {
    vec3 d = w - cam.ro;
    float z = max(dot(d, cam.fw), 0.05);
    return vec3(vec2(dot(d, cam.rt), dot(d, cam.up)) * cam.fl / z, z);
}

// One bloom stroke over a 0...1 cycle: a quick open, then a long settle.
float flowerStroke(float t) {
    t = fract(t);
    return smoothstep(0.0, 0.1, t) * exp(-max(t - 0.1, 0.0) * 4.0);
}

vec2 flowerRotate(vec2 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

struct FlowerBody {
    vec3 center;
    float lean;      // the bloom tips toward the viewer about x
    float sway;      // and sways side to side about z
    float spin;      // slow turn about its own axis
    float R;         // size
    float open;      // 0 closed bud ... 1 wide open
    float kick;
    float snare;
    float time;
    float hue;
    float glow;
};

vec3 flowerLocal(in FlowerBody f, vec3 w) {
    vec3 q = w - f.center;
    q.xy = flowerRotate(q.xy, -f.sway);
    q.yz = flowerRotate(q.yz, -f.lean);
    q.xz = flowerRotate(q.xz, -f.spin);
    return q;
}

vec3 flowerWorld(in FlowerBody f, vec3 q) {
    q.xz = flowerRotate(q.xz, f.spin);
    q.yz = flowerRotate(q.yz, f.lean);
    q.xy = flowerRotate(q.xy, f.sway);
    return q + f.center;
}

struct PetalHit {
    float sheet;   // signed distance to the petal sheet (thickness included)
    float inside;  // how far inside the outline, negative outside (flower sizes)
    float along;   // 0 base ... 1 tip
    float across;  // -1 ... 1 across the petal
    float index;   // petal number within the ring
    float shade;   // a cheap light term from the sheet's facing
};

// The nearest petal of ring 'ring' to flower-frame point q.
PetalHit flowerPetal(in FlowerBody f, int ring, vec3 q) {
    float R = f.R;
    int n = kRingCount[ring];
    float sw = 6.2831853 / float(n);
    float offset = float(ring) * 0.61;
    float a = atan(q.z, q.x);
    float idx = floor((a - offset) / sw + 0.5);
    float ac = offset + idx * sw;
    vec2 xz = flowerRotate(q.xz, -ac);
    float len = kRingLength[ring] * R;
    float wid = kRingWidth[ring] * R;
    // Each petal opens a little differently; the snare runs a ripple around the ring.
    float h = hash11(idx * 1.37 + float(ring) * 7.1 + f.hue * 13.0);
    float ripple = 0.12 * f.snare * sin(ac * 3.0 - f.time * 10.0);
    float theta = mix(kRingClosed[ring], kRingOpen[ring], clamp(f.open + 0.06 * (h - 0.5) + ripple, 0.0, 1.0));
    float r0 = (0.05 + 0.035 * float(ring)) * R;
    vec2 rel = vec2(xz.x - r0, q.y);
    vec2 dir = vec2(sin(theta), cos(theta));
    vec2 nrm = vec2(cos(theta), -sin(theta));
    float u = dot(rel, dir);
    float w = dot(rel, nrm);
    float v = xz.y;
    float t = clamp(u / len, 0.0, 1.0);
    // Curl back at the tip, cup across, and flutter on the kick.
    w -= (0.18 + 0.25 * f.open) * len * t * t;
    w -= 0.35 * v * v / wid;
    w += f.kick * 0.04 * R * sin(t * 14.0 - f.time * 32.0 + h * 6.0) * t;
    float halfWidth = wid * pow(sin(3.14159265 * min(t * 0.92 + 0.04, 1.0)), 0.65) * (1.0 - 0.25 * t);
    float thick = (0.026 - 0.012 * t) * R;
    PetalHit hit;
    hit.sheet = abs(w) - thick;
    hit.inside = min(min(halfWidth - abs(v), u), len - u);
    hit.along = t;
    hit.across = v / max(halfWidth, 1e-4);
    hit.index = idx;
    vec3 n3 = normalize(vec3(nrm.x, nrm.y, 0.0));
    hit.shade = 0.55 + 0.45 * abs(dot(n3, normalize(vec3(0.2, 0.85, 0.5))));
    return hit;
}

struct FlowerLayer {
    vec3 light;
    float transmit;
};

FlowerLayer flowerDraw(
    in FlowerBody f, in FlowerCamera cam, vec2 sp, float px, float dither,
    float hat, float highs) {
    FlowerLayer res;
    res.light = vec3(0.0);
    res.transmit = 1.0;
    float R = f.R;
    vec3 pc = flowerProject(cam, f.center);
    float scale = cam.fl / pc.z;
    if (abs(sp.x - pc.x) > 1.6 * R * scale + 0.2 || sp.y > pc.y + 1.5 * R * scale) return res;

    vec3 hueColor = paletteAt(f.hue);
    vec3 inner = mix(mix(u.c1.rgb, hueColor, 0.35), vec3(1.0, 0.85, 0.95), 0.2);
    vec3 middle = mix(mix(u.c2.rgb, hueColor, 0.4), vec3(0.9, 0.95, 1.0), 0.25);
    vec3 outer = mix(mix(u.c0.rgb, u.c2.rgb, 0.4), hueColor, 0.35);
    vec3 heart = mix(vec3(1.0, 0.85, 0.45), u.c1.rgb, 0.25);

    // The stem: a glowing stalk curving down out of frame, behind the bloom, and a halo around it.
    vec3 base = flowerWorld(f, vec3(0.0, -0.06 * R, 0.0));
    vec3 pb = flowerProject(cam, base);
    float stemLength = 3.0;
    float sc = cam.fl / pb.z;
    float s = (pb.y - sp.y) / (sc * stemLength);
    vec3 back = vec3(0.0);
    if (s > 0.0 && s < 1.0) {
        float bend = 0.25 * s * s * sin(f.time * 0.3 + f.hue * 9.0) + 0.1 * s * sin(f.time * 0.5 + f.hue * 4.0);
        vec3 pw = base + vec3(bend - f.sway * s * 0.8, -s * stemLength, 0.1 * s);
        vec3 pp = flowerProject(cam, pw);
        float w = max(0.022 * R * cam.fl / pp.z, px);
        float d = abs(sp.x - pp.x);
        vec3 stemTint = mix(mix(u.c0.rgb, vec3(0.25, 0.7, 0.45), 0.6), vec3(0.8, 1.0, 0.85), 0.2);
        back += stemTint * (exp(-d * d / (w * w)) * 0.35 + exp(-d / (w * 6.0)) * 0.04) * (1.0 - s);
    }
    vec2 halo = (sp - pc.xy) / (R * scale);
    back += mix(middle, heart, 0.4) * exp(-length(halo) * 1.8) * 0.06 * f.glow;

    // The bloom: march through its glassy petals and its glowing heart.
    vec3 rd = normalize(cam.fw * cam.fl + cam.rt * sp.x + cam.up * sp.y);
    vec3 oc = cam.ro - f.center;
    float bound = R * 1.2;
    float bb = dot(oc, rd);
    float cc = dot(oc, oc) - bound * bound;
    float disc = bb * bb - cc;
    vec3 bloom = vec3(0.0);
    float transmit = 1.0;
    if (disc > 0.0) {
        float sqd = sqrt(disc);
        float t0 = max(-bb - sqd, 0.0);
        float t1 = -bb + sqd;
        const int steps = 64;
        float dt = (t1 - t0) / float(steps);
        float edgeSoft = max(0.7 * dt, 0.004 * R);
        float sparkle = 0.6 + 1.8 * hat + 0.8 * highs;
        for (int i = 0; i < steps; i++) {
            vec3 w = cam.ro + rd * (t0 + dt * (float(i) + dither));
            vec3 q = flowerLocal(f, w);
            vec3 emit = vec3(0.0);
            float density = 0.0;
            for (int ring = 0; ring < 3; ring++) {
                PetalHit hit = flowerPetal(f, ring, q);
                float outline = smoothstep(-edgeSoft, edgeSoft, hit.inside);
                float sheet = smoothstep(edgeSoft, -edgeSoft, hit.sheet) * outline;
                if (sheet < 0.001) continue;
                float band = bandAt(fract((hit.index + float(ring) * 5.0) / 24.0) * 0.85 + 0.05);
                float veins = pow(abs(cos(hit.across * 4.71)), 8.0) * smoothstep(0.05, 0.4, hit.along);
                float edge = exp(-max(hit.inside, 0.0) / max(0.025 * R, edgeSoft));
                vec3 tint = ring == 0 ? inner : (ring == 1 ? mix(inner, middle, 0.6) : mix(middle, outer, 0.5));
                tint = mix(mix(vec3(1.0, 0.95, 0.9), tint, 0.75), tint * 1.3, hit.along);
                emit += tint * sheet * hit.shade * (0.9 + 0.9 * hit.along + veins * (0.5 + 2.5 * band) + edge * 1.4);
                density += sheet;
            }
            // The heart: a glowing core and a ring of stamens with bright anthers.
            float core = length(q - vec3(0.0, 0.03 * R, 0.0)) - 0.07 * R;
            float coreDensity = smoothstep(edgeSoft, -edgeSoft, core);
            emit += heart * coreDensity * 1.6;
            density += coreDensity;
            float sa = atan(q.z, q.x);
            float ssw = 6.2831853 / 14.0;
            float sidx = floor(sa / ssw + 0.5);
            vec2 sxz = flowerRotate(q.xz, -sidx * ssw);
            vec3 tip = vec3(0.17 * R * (0.7 + 0.3 * f.open), 0.24 * R, 0.0);
            vec3 sq3 = vec3(sxz.x, q.y, sxz.y);
            float hseg = clamp(dot(sq3, tip) / dot(tip, tip), 0.0, 1.0);
            float filament = length(sq3 - tip * hseg) - 0.006 * R;
            emit += heart * smoothstep(max(edgeSoft, 0.004 * R), 0.0, filament) * 0.6;
            float anther = length(sq3 - tip) / max(0.022 * R, edgeSoft);
            emit += mix(heart, vec3(1.0), 0.5) * exp(-anther * anther) * sparkle * 1.4;

            bloom += emit * transmit * dt / R * 1.5 * f.glow;
            transmit *= exp(-density * dt / R * 3.0);
        }
    }
    res.light = back * transmit + bloom;
    res.transmit = transmit;
    return res;
}

void main() {
    float aspect = u.resTime.x / u.resTime.y;
    float intensity = u.extra.z;
    float time = u.resTime.z * mix(0.45, 1.0, intensity);
    float beats = u.resTime.w;
    float kick = u.env.x * intensity;
    float snare = u.env.y * intensity;
    float hat = u.env.z * intensity;
    float energy = u.wobble.z;
    float drop = u.misc.y;
    float bass = bandAt(0.05);
    float highs = bandAt(0.8);

    vec2 p = (vUv - 0.5) * vec2(aspect, 1.0) * 2.0;
    vec2 sp = vec2(p.x, -p.y);
    float px = 2.0 / max(u.resTime.y, 1.0);
    vec2 pix = vUv * u.resTime.xy;
    float dither = fract(52.9829189 * fract(dot(pix, vec2(0.06711056, 0.00583715))));

    FlowerCamera cam;
    cam.ro = vec3(0.0, 0.85, 3.2);
    cam.fw = normalize(vec3(0.0, -0.1, 0.0) - cam.ro);
    cam.rt = normalize(cross(cam.fw, vec3(0.0, 1.0, 0.0)));
    cam.up = cross(cam.rt, cam.fw);
    cam.fl = 2.2;

    // ---- The night garden: a deep gradient, a low glow, pollen and out-of-focus fireflies ----------
    vec3 night = mix(u.c0.rgb * 0.02, vec3(0.006, 0.002, 0.02), 0.75);
    float lowGlow = exp(-(sp.y + 1.0) * 1.4);
    vec3 col = night * (0.6 + 1.2 * clamp(0.5 - 0.5 * sp.y, 0.0, 1.0));
    col += mix(u.c1.rgb, u.c2.rgb, 0.5) * lowGlow * (0.025 + 0.03 * bass);
    for (int layer = 0; layer < 2; layer++) {
        float fl = float(layer);
        float cs = layer == 0 ? 0.08 : 0.22;
        vec2 drift = vec2(sin(time * 0.1 + fl) * 0.05, -time * (0.03 + 0.03 * fl));
        vec2 c;
        float h;
        vec2 q = sp + drift + fl * 5.3;
        if (fxCell(q, cs, 47.0 + fl * 3.0, layer == 0 ? 0.3 : 0.18, c, h)) {
            float size = max((layer == 0 ? 0.0035 : 0.018) * (0.5 + h), px * 0.8);
            float d = length(q - c);
            float mote = exp(-d * d / (size * size)) * (layer == 0 ? 1.0 : 0.25);
            float tw = 0.5 + 0.5 * sin(time * (0.8 + 2.0 * h) + h * 40.0) + 0.8 * hat + 0.4 * highs;
            vec3 tint = layer == 0 ? mix(vec3(1.0, 0.85, 0.5), u.c1.rgb, 0.3) : mix(u.c2.rgb, vec3(0.8, 1.0, 0.6), 0.4);
            col += tint * mote * tw * 0.35;
        }
    }

    // ---- The flowers, far to near ------------------------------------------------------------------
    FlowerBody flowers[4];
    float depths[4];
    int order[4];
    for (int i = 0; i < kFlowers; i++) {
        float fi = float(i);
        float hi = hash11(fi * 5.77 + 3.0);
        FlowerBody f;
        f.time = time + fi * 11.0;
        f.R = kFlowerSize[i] * (1.0 + 0.06 * bass);
        float stroke = flowerStroke(beats * kFlowerRate[i] + kFlowerOffset[i] * kFlowerRate[i] + time * 0.01);
        float strength = (0.6 + 0.3 * energy + 0.4 * bass) * intensity;
        f.open = clamp(0.3 + 0.25 * energy + 0.2 * bass + 0.3 * stroke * strength + 0.35 * drop + 0.15 * kick, 0.0, 1.0);
        f.kick = kick * (0.6 + 0.4 * hi);
        f.snare = snare;
        f.center = vec3(
            kFlowerHome[i] + 0.06 * sin(time * (0.2 + 0.1 * hi) + fi),
            kFlowerHomeY[i] + 0.04 * sin(time * 0.3 + fi * 2.0) + 0.03 * stroke * strength,
            kFlowerDepth[i]);
        f.lean = 0.3 + 0.08 * sin(time * 0.17 + fi);
        f.sway = 0.12 * sin(time * (0.25 + 0.1 * hi) + fi * 1.7) + 0.05 * f.kick;
        f.spin = time * (0.03 + 0.03 * hi) + fi * 2.3;
        f.hue = hi;
        f.glow = (0.8 + 0.45 * bass + 0.35 * drop + 0.15 * energy) * (1.0 + 1.3 * f.kick + 0.4 * snare);
        flowers[i] = f;
        depths[i] = dot(f.center - cam.ro, cam.fw);
        order[i] = i;
    }
    for (int a = 0; a < kFlowers - 1; a++) {
        for (int b = 0; b < kFlowers - 1 - a; b++) {
            if (depths[order[b]] < depths[order[b + 1]]) {
                int t = order[b];
                order[b] = order[b + 1];
                order[b + 1] = t;
            }
        }
    }
    for (int n = 0; n < kFlowers; n++) {
        int i = order[n];
        FlowerLayer layer = flowerDraw(flowers[i], cam, sp, px, dither, hat, highs);
        float fog = exp(-max(depths[i] - 3.0, 0.0) * 0.3);
        col = col * layer.transmit + layer.light * fog;
    }

    col = fxFlash(col, 0.35);
    col = fxTonemap(col, 1.2);
    col = fxVignette(col, p, 0.14);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
`,
};
