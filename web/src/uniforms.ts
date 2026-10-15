import { FlashLimiter, intenseDrive, type IntenseDrive } from "./safety.js";
import { SoundVisualState } from "./state.js";

/**
 * What a ported shader reads, laid out exactly as the Metal side lays it out (IntenseRenderer.swift's
 * `IntenseUniforms`, WobbleTunnelRenderer.swift's `fill` and IntenseAux.swift), so a GLSL port reads the same names
 * and indices as the MSL it came from:
 *
 * - `uniforms`: the ten float4s of `IntenseUniforms` (resTime, env, wobble, fx, misc, c0, c1, c2, extra, flashColor).
 * - `data`: one R32F texture, DATA_WIDTH x DATA_ROWS, standing in for the Metal fragment buffers:
 *   row 0 = buffer 1 (the 64-band spectrum), row 1 = buffer 2 (the 512-sample waveform), row 2 = buffer 4 (the 128 aux
 *   scalars), rows 3 ... 4 = buffer 5 (6 history traces x 128 points, row-major across the two rows).
 */
export const UNIFORM_NAMES = [
  "resTime",
  "env",
  "wobble",
  "fx",
  "misc",
  "c0",
  "c1",
  "c2",
  "extra",
  "flashColor",
] as const;

export const DATA_WIDTH = 512;
export const DATA_ROWS = 5;

export const DataRow = { spectrum: 0, waveform: 1, aux: 2, history: 3 } as const;

/** The aux scalar layout (IntenseAux.swift, buffer 4). */
export const Aux = {
  scalarCount: 128,
  peaks: 0,
  pitchClasses: 64,
  pads: 76,
  keyTonic: 108,
  keyConfidence: 109,
  keyMinor: 110,
  rollHasNotes: 111,
  peak: 112,
  rms: 113,
  peakHold: 114,
  chroma: 115,
  rollLow: 116,
  rollSpan: 117,
  scopeTrigger: 118,
  silent: 119,
  historyLayers: 6,
  historyPoints: 128,
  historyStride: 3,
} as const;

/** The first rising zero crossing in the leading 128 samples (from `base`), so a trace holds still; 0 when none. */
export function scopeTrigger(wave: ArrayLike<number>, base = 0): number {
  if (wave.length < base + 384 + 128) return 0;
  for (let i = 1; i < 128; i++) if (wave[base + i - 1] < 0 && wave[base + i] >= 0) return i;
  return 0;
}

/** The per-frame inputs of a ported shader, filled in place from a `SoundVisualState`. Allocates once. */
export class ShaderInputs {
  /** 10 x vec4, in UNIFORM_NAMES order. */
  readonly uniforms = new Float32Array(40);
  readonly data = new Float32Array(DATA_WIDTH * DATA_ROWS);
  readonly limiter = new FlashLimiter();
  drive: IntenseDrive = { flash: 0, intensity: 1, glitch: 0, flashColor: [1, 1, 1] };

  /** Writes `state`'s picture for a `width` x `height` target. */
  fill(state: SoundVisualState, width: number, height: number): void {
    const p = state.palette;
    // IntenseDrive(state:): a snare on the drop and the state's flash ask for a flash.
    this.drive = intenseDrive(
      Math.max(state.flash, state.snare * state.dropAmount),
      Math.max(state.glitch, state.dropAmount * 0.55 + state.snare * 0.35),
      p.c2,
      state.calm,
      state.time,
      this.limiter,
    );
    const d = this.drive;
    const u = this.uniforms;
    u.set([width, height, state.time % 3600, state.beats % 4096], 0);
    u.set([state.kick, state.snare, state.hat, state.impact], 4);
    u.set([state.wobbleCutoff, state.wobblePhase, state.energy, state.glitch], 8);
    u.set([state.flash, state.chroma, state.shakeOffset[0], state.shakeOffset[1]], 12);
    u.set([state.wild, state.dropAmount, state.travel % 4096, state.barPhase], 16);
    u.set([p.c0[0], p.c0[1], p.c0[2], 1], 20);
    u.set([p.c1[0], p.c1[1], p.c1[2], 1], 24);
    u.set([p.c2[0], p.c2[1], p.c2[2], 1], 28);
    u.set([d.flash, 0, d.intensity, d.glitch], 32);
    u.set([d.flashColor[0], d.flashColor[1], d.flashColor[2], state.calm ? 1 : 0], 36);

    const data = this.data;
    data.set(state.spectrum, DataRow.spectrum * DATA_WIDTH);
    data.set(state.waveform, DataRow.waveform * DATA_WIDTH);
    const aux = DataRow.aux * DATA_WIDTH;
    data.set(state.peaks, aux + Aux.peaks);
    data[aux + Aux.peak] = state.peak;
    data[aux + Aux.rms] = state.rms;
    data[aux + Aux.peakHold] = state.peakHold;
    data[aux + Aux.chroma] = state.chroma;
    data[aux + Aux.keyTonic] = -1;
    data[aux + Aux.rollLow] = 21;
    data[aux + Aux.rollSpan] = 12;
    data[aux + Aux.scopeTrigger] = scopeTrigger(state.waveform);
    data[aux + Aux.silent] = state.isSilent ? 1 : 0;
    this.fillHistory(state);
  }

  private fillHistory(state: SoundVisualState): void {
    const depth = SoundVisualState.historyDepth;
    const samples = SoundVisualState.sampleCount;
    const out = DataRow.history * DATA_WIDTH;
    for (let age = 0; age < Aux.historyLayers; age++) {
      const base = out + age * Aux.historyPoints;
      if (age >= state.historyCount) {
        this.data.fill(0, base, base + Aux.historyPoints);
        continue;
      }
      const slot = (((state.historyHead - age) % depth) + depth) % depth;
      const start = slot * samples;
      const first = scopeTrigger(state.history, start);
      for (let k = 0; k < Aux.historyPoints; k++) this.data[base + k] = state.history[start + first + Aux.historyStride * k];
    }
  }
}
