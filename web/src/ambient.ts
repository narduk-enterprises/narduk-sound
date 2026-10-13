import { SoundFrameLayout, type SoundFrame } from "./frame.js";
import type { MusicContext } from "./inference.js";

const f = Math.fround;

/**
 * The picture while a track plays and nothing is known about its sound (`AmbientDrift` in sound-tv,
 * Sources/Music/AmbientDrift.swift): a quiet, slow breathing and nothing else. The page cannot hear the beat, and this
 * does not pretend to: no beat clock (`isRunning` is false), no hits, a constant step, an energy near 0.15 that rises
 * and falls over about 9 and 23 seconds, and a dim low-weighted spectrum that breathes with it.
 *
 * Every value is a pure function of the time `t`, so the same moment always draws the same picture. The functions write
 * into the object they are given (a `SoundFrame` or `MusicContext` the caller owns), so a frame loop allocates nothing.
 */
export class AmbientDrift {
  static readonly baseEnergy = 0.15;
  /** Peak deviation from `baseEnergy`; the band is `baseEnergy` plus or minus `swing`. */
  static readonly swing = 0.035;

  static energy(t: number): number {
    const slow = Math.sin((2 * Math.PI * t) / 23 + 1.3);
    const fast = Math.sin((2 * Math.PI * t) / 9);
    return f(AmbientDrift.baseEnergy + f(AmbientDrift.swing * f(0.45 * slow + 0.55 * fast)));
  }

  /** `MusicContext(energy:, isRunning: false)` at `t`, written into `into` (the hit counters are left as they are). */
  static music(t: number, into: MusicContext): MusicContext {
    into.step = 0;
    into.section = "intro";
    into.energy = AmbientDrift.energy(t);
    into.wobblePhase = 0;
    into.wobbleCutoff = 0;
    into.isRunning = false;
    into.phraseProgress = 0;
    into.dropQueued = false;
    return into;
  }

  /** The frame at `t`, written into `into` with the given `sequence`. */
  static frame(t: number, sequence: number, into: SoundFrame): SoundFrame {
    const level = AmbientDrift.energy(t);
    for (let band = 0; band < SoundFrameLayout.spectrumCount; band++) {
      // Weighted to the lows, with a slow ripple that drifts along the bands.
      const weight = f(Math.exp(-band / 14));
      const ripple = f(0.85 + 0.15 * Math.sin(2 * Math.PI * (t / 11 + band / 24)));
      into.spectrum[band] = f(Math.min(f(f(f(level * 1.4) * weight) * ripple), 1));
    }
    into.chroma.fill(0);
    into.waveform.fill(0);
    const rms = f(20 * Math.log10(Math.max(f(level * 0.2), 1e-4)));
    into.sequence = sequence;
    into.time = t;
    into.rmsDB = rms;
    into.peakDB = f(rms + 6);
    return into;
  }
}
