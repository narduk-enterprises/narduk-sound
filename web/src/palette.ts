/**
 * The palette contract (docs/sound-contract.md section 6), ported from Sources/NardukSoundVisuals/SoundPalette.swift:
 * three blendable neon colors drive every visualizer. Visualizers take a palette and never name a color; apps supply
 * theirs. Components are 0 ... 1.
 */
export type RGB = readonly [number, number, number];

export interface SoundPalette {
  readonly c0: RGB;
  readonly c1: RGB;
  readonly c2: RGB;
}

/** The five sections of a song (`SongSection` in NardukMusicCore). */
export type SongSection = "intro" | "build" | "drop" | "breakdown" | "drop2";

/** What picks the palette: a song section, or a 0 ... 1 scalar for sources with no music. */
export type SoundPaletteDriver = { section: SongSection } | { scalar: number };

/** An app's palette table. The state calls it with a section when it knows one and with a scalar otherwise. */
export interface SoundPaletteProvider {
  palette(driver: SoundPaletteDriver): SoundPalette;
}

const clamp01 = (v: number) => Math.min(Math.max(v, 0), 1);
const lerp3 = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];

export function mixed(a: SoundPalette, b: SoundPalette, t: number): SoundPalette {
  return { c0: lerp3(a.c0, b.c0, t), c1: lerp3(a.c1, b.c1, t), c2: lerp3(a.c2, b.c2, t) };
}

export function oklab(c: RGB): RGB {
  const lin = (v: number) => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
  const r = lin(c[0]);
  const g = lin(c[1]);
  const b = lin(c[2]);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

export function fromOklab(lab: RGB): RGB {
  const l = Math.pow(lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2], 3);
  const m = Math.pow(lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2], 3);
  const s = Math.pow(lab[0] - 0.0894841775 * lab[1] - 1.291485548 * lab[2], 3);
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const b = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  const gamma = (v: number) => {
    const x = clamp01(v);
    return x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055;
  };
  return [gamma(r), gamma(g), gamma(b)];
}

/** A blend through OKLab, so the midpoint of two hues keeps its lightness and chroma. */
export function mixedPerceptually(a: SoundPalette, b: SoundPalette, t: number): SoundPalette {
  const mix = (x: RGB, y: RGB) => fromOklab(lerp3(oklab(x), oklab(y), t));
  return { c0: mix(a.c0, b.c0), c1: mix(a.c1, b.c1), c2: mix(a.c2, b.c2) };
}

/** Scales each color's saturation around its luma; > 1 pushes it past the source palette. */
export function saturated(p: SoundPalette, amount: number): SoundPalette {
  const sat = (c: RGB): RGB => {
    const luma = c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
    return [clamp01(luma + (c[0] - luma) * amount), clamp01(luma + (c[1] - luma) * amount), clamp01(luma + (c[2] - luma) * amount)];
  };
  return { c0: sat(p.c0), c1: sat(p.c1), c2: sat(p.c2) };
}

/** Cyclic sample c0 -> c1 -> c2 -> c0 with a smoothstep in each segment; `t` may be any value. */
export function sample(p: SoundPalette, t: number): RGB {
  const f = (t - Math.floor(t)) * 3;
  const segment = Math.trunc(f) % 3;
  const local = f - Math.trunc(f);
  const s = local * local * (3 - 2 * local);
  switch (segment) {
    case 0:
      return lerp3(p.c0, p.c1, s);
    case 1:
      return lerp3(p.c1, p.c2, s);
    default:
      return lerp3(p.c2, p.c0, s);
  }
}

/** The palette the gallery and the tests use: Wirewatcher's section table, and a c0 -> c1 -> c2 sweep for a scalar. */
export class DefaultSoundPaletteProvider implements SoundPaletteProvider {
  static readonly cyan: RGB = [0.13, 0.72, 0.9];
  static readonly lime: RGB = [0.62, 0.84, 0.22];
  static readonly magenta: RGB = [1.0, 0.18, 0.78];
  static readonly violet: RGB = [0.48, 0.3, 1.0];
  static readonly blue: RGB = [0.16, 0.34, 0.95];
  static readonly teal: RGB = [0.08, 0.95, 0.78];
  static readonly amber: RGB = [1.0, 0.72, 0.18];
  static readonly orange: RGB = [1.0, 0.42, 0.1];

  palette(driver: SoundPaletteDriver): SoundPalette {
    const P = DefaultSoundPaletteProvider;
    if ("section" in driver) {
      switch (driver.section) {
        case "intro":
          return { c0: P.cyan, c1: P.blue, c2: P.teal };
        case "build":
          return { c0: P.cyan, c1: P.lime, c2: P.amber };
        case "drop":
          return { c0: P.lime, c1: P.magenta, c2: P.cyan };
        case "breakdown":
          return { c0: P.violet, c1: P.blue, c2: P.cyan };
        case "drop2":
          return { c0: P.orange, c1: P.magenta, c2: P.lime };
      }
    }
    const base: SoundPalette = { c0: P.cyan, c1: P.violet, c2: P.magenta };
    const t = clamp01(driver.scalar);
    // Slide the three colors along the cycle so a rising signal visibly changes the whole palette.
    return { c0: sample(base, t), c1: sample(base, t + 1 / 3), c2: sample(base, t + 2 / 3) };
  }
}
