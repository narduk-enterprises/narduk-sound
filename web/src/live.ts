import type { SoundVisualState } from "./state.js";
import { Aux, DATA_WIDTH, DataRow, type ShaderInputs } from "./uniforms.js";

const clamp01 = (x: number) => (x < 0 ? 0 : x > 1 ? 1 : x);

/** Where the shaders read the channels `LiveDrive` rewrites (`ShaderInputs.uniforms`, 10 x vec4). */
const U = { kick: 4, snare: 5, hat: 6, energy: 10, wild: 16 } as const;

/** A signal's running mean and typical deviation from it, to read a value as how far above or below its own norm it is. */
class Norm {
  mean = 0;
  deviation = 0;
  private primed = false;

  track(x: number, dt: number, meanSeconds: number, deviationSeconds: number): void {
    if (!this.primed) {
      this.mean = x;
      this.primed = true;
    }
    this.mean += (x - this.mean) * Math.min(1, dt / meanSeconds);
    this.deviation += (Math.abs(x - this.mean) - this.deviation) * Math.min(1, dt / deviationSeconds);
  }

  /** 0.5 at the norm, 0 or 1 at `reach` deviations below or above it; the deviation counts as at least `minDeviation`. */
  position(x: number, reach: number, minDeviation: number): number {
    return clamp01(0.5 + (0.5 * (x - this.mean)) / (reach * Math.max(this.deviation, minDeviation)));
  }

  reset(): void {
    this.primed = false;
  }
}

/**
 * The web-only drive layer that makes a live stream read as loudly as a recording does in the Swift visualizers.
 *
 * Broadcast audio is compressed: its loudness stays within a few dB and each band within a few percent, so the state's
 * smoothed `energy`, `wild` and spectrum sit nearly still (KZFR: energy 0.27 ... 0.33, the mean band level moves by
 * 0.015). The state's math is the Swift contract (pinned by `fixtures/sound-contract.json`), so this layer sits after it:
 * `SoundVisualizer.step` runs `apply` on the filled `ShaderInputs`, and the shaders read the result through the same
 * uniforms and the same spectrum row (the Metal ports and the KZFR logo look need no change).
 *
 * It does four things, each a no-op on a source that already moves enough:
 * - **energy / wild** (`u.wobble.z`, `u.misc.x`): the slow energy and a fast level are read against their own running
 *   mean and deviation, so a 6 dB swing spans the range, and kicks and snares add a short lift.
 * - **spectrum and caps** (the data row and `Aux.peaks`): each band's deviation from its own running mean is scaled up
 *   until it reaches a target size (never down, at most `maxBandGain`), so compressed bands pulse and dynamic ones are
 *   untouched. Caps use the same monotone map, so they stay at or above the bars.
 * - **kick and snare**: a sharper curve, so successive hits read as separate pulses instead of one steady glow (a busy
 *   passage kept the snare lit 95 % of the time).
 * - **hat**: lifted to full scale (a closed hat peaks at 0.6 and lasts about 70 ms).
 *
 * The flash path is never touched (`u.fx`, `u.extra`, the limiter): the photosensitivity limits hold. Silence and calm
 * (Reduce Motion) pass through unchanged. Every buffer is allocated in the constructor and time comes in as `now`.
 */
export class LiveDrive {
  /** The target size of a band's typical deviation from its mean (0 ... 1 band units). */
  static readonly bandDeviation = 0.13;
  /** The most a band's deviation is scaled up. */
  static readonly maxBandGain = 3;
  static readonly kickPunch = 1.4;
  static readonly snarePunch = 1.3;
  static readonly hatGain = 1.6;

  /** False passes everything through untouched (for comparing). */
  enabled = true;

  private readonly energyNorm = new Norm();
  private readonly levelNorm = new Norm();
  private level = 0;
  private lastNow = -Infinity;
  private readonly mean = new Float32Array(64);
  private readonly deviation = new Float32Array(64);
  private bandsPrimed = false;

  /** Forgets the running ranges and means: call it when the source changes. */
  reset(): void {
    this.energyNorm.reset();
    this.levelNorm.reset();
    this.level = 0;
    this.lastNow = -Infinity;
    this.mean.fill(0);
    this.deviation.fill(0);
    this.bandsPrimed = false;
  }

  /**
   * Rewrites the drive channels of `inputs` (just filled from `state`) for the frame at `now` seconds. `amount` (0 ... 1,
   * default 1) mixes the result with what `inputs` held: a timeline fading to the ambient drift lowers it to 0, so the
   * quiet breathing is never stretched.
   */
  apply(inputs: ShaderInputs, state: SoundVisualState, now: number, amount = 1): void {
    if (!this.enabled || state.calm || !(amount > 0)) return;
    const mix = amount >= 1 ? (_before: number, after: number) => after : (before: number, after: number) => before + (after - before) * amount;
    const dt = this.lastNow === -Infinity ? 1 / 60 : Math.min(Math.max(now - this.lastNow, 0), 0.1);
    this.lastNow = now;
    if (state.isSilent || dt <= 0) return;
    const u = inputs.uniforms;

    // Envelopes.
    const kick = Math.pow(state.kick, LiveDrive.kickPunch);
    const wildBefore = u[U.wild];
    const energyBefore = u[U.energy];
    u[U.kick] = mix(u[U.kick], kick);
    const snare = Math.pow(state.snare, LiveDrive.snarePunch);
    u[U.snare] = mix(u[U.snare], snare);
    u[U.hat] = mix(u[U.hat], Math.min(1, state.hat * LiveDrive.hatGain));

    // Energy and wild: the slow energy and the fast level, each against its own range, plus a lift on a hit.
    this.level += (state.level - this.level) * Math.min(1, dt * (state.level > this.level ? 20 : 5));
    this.energyNorm.track(state.energy, dt, 8, 8);
    this.levelNorm.track(this.level, dt, 8, 8);
    const relative = 0.4 * this.energyNorm.position(state.energy, 2.5, 0.01) + 0.6 * this.levelNorm.position(this.level, 2.5, 0.02);
    // A quarter absolute, so a loud passage still reads louder than a quiet one after the norm catches up.
    const stretched = 0.75 * relative + 0.25 * clamp01(state.energy / 0.45);
    const lift = 0.1 * Math.max(kick, Math.fround(snare));
    const energy = clamp01(0.06 + 0.8 * stretched + lift);
    u[U.energy] = mix(energyBefore, energy);
    u[U.wild] = mix(wildBefore, clamp01(state.wild + (energy - state.energy)));

    // Spectrum and caps: scale each band's deviation from its running mean up to the target size.
    const row = DataRow.spectrum * DATA_WIDTH;
    const caps = DataRow.aux * DATA_WIDTH + Aux.peaks;
    const data = inputs.data;
    const { mean, deviation } = this;
    const meanRate = Math.min(1, dt / 2);
    const deviationRate = Math.min(1, dt / 5);
    for (let b = 0; b < 64; b++) {
      const value = state.spectrum[b];
      if (!this.bandsPrimed) mean[b] = value;
      mean[b] += (value - mean[b]) * meanRate;
      deviation[b] += (Math.abs(value - mean[b]) - deviation[b]) * deviationRate;
      const gain = Math.min(Math.max(LiveDrive.bandDeviation / (deviation[b] + 1e-3), 1), LiveDrive.maxBandGain);
      const bar = clamp01(mean[b] + (value - mean[b]) * gain);
      const cap = Math.max(bar, clamp01(mean[b] + (state.peaks[b] - mean[b]) * gain));
      data[row + b] = mix(data[row + b], bar);
      data[caps + b] = mix(data[caps + b], cap);
    }
    this.bandsPrimed = true;
  }
}
