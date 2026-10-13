import { describe, expect, it } from "vitest";
import { Aux, DATA_WIDTH, DataRow, LiveDrive, ShaderInputs, SoundVisualState, emptyFrame } from "../src/index.js";

/** A broadcast-compressed stream: loudness within ~3 dB and every band within a few percent, a pulse on each beat. */
function compressedFrame(sequence: number, t: number, bpm = 120): ReturnType<typeof emptyFrame> {
  const frame = emptyFrame();
  frame.sequence = sequence;
  frame.time = t;
  const beat = 60 / bpm;
  const pulse = Math.exp(-(t % beat) * 10);
  frame.rmsDB = -25 + 1.5 * pulse;
  frame.peakDB = -17 + 1.5 * pulse;
  for (let b = 0; b < 64; b++) frame.spectrum[b] = 0.4 + 0.03 * pulse + 0.1 * Math.sin(b * 0.3);
  return frame;
}

function run(seconds: number, live: LiveDrive, options: { calm?: boolean; silent?: boolean } = {}) {
  const state = new SoundVisualState();
  const inputs = new ShaderInputs();
  const energy: number[] = [];
  const stateEnergy: number[] = [];
  const bars: number[] = [];
  const stateBars: number[] = [];
  for (let i = 1; i <= seconds * 60; i++) {
    const t = i / 60;
    const frame = compressedFrame(i, t);
    if (options.silent) {
      frame.rmsDB = -120;
      frame.peakDB = -120;
      frame.spectrum.fill(0);
    }
    state.update(frame, t, { calm: options.calm });
    inputs.fill(state, 800, 600);
    live.apply(inputs, state, t);
    if (t > seconds / 2) {
      energy.push(inputs.uniforms[10]);
      stateEnergy.push(state.energy);
      bars.push(inputs.data[DataRow.spectrum * DATA_WIDTH + 10]);
      stateBars.push(state.spectrum[10]);
    }
  }
  return { state, inputs, energy, stateEnergy, bars, stateBars };
}

const swing = (a: number[]) => Math.max(...a) - Math.min(...a);

describe("LiveDrive", () => {
  it("widens the energy and the spectrum of a compressed stream", () => {
    const { energy, stateEnergy, bars, stateBars } = run(12, new LiveDrive());
    expect(swing(energy)).toBeGreaterThan(swing(stateEnergy) * 3);
    expect(swing(bars)).toBeGreaterThan(swing(stateBars) * 2);
    for (const v of [...energy, ...bars]) {
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThanOrEqual(1);
    }
  });

  it("leaves a steady signal steady (it does not amplify noise)", () => {
    const live = new LiveDrive();
    const state = new SoundVisualState();
    const inputs = new ShaderInputs();
    const energy: number[] = [];
    for (let i = 1; i <= 600; i++) {
      const frame = emptyFrame();
      frame.sequence = i;
      frame.rmsDB = -20;
      frame.peakDB = -12;
      frame.spectrum.fill(0.5);
      state.update(frame, i / 60);
      inputs.fill(state, 800, 600);
      live.apply(inputs, state, i / 60);
      if (i > 400) energy.push(inputs.uniforms[10]);
    }
    expect(swing(energy)).toBeLessThan(0.05);
  });

  it("keeps the caps at or above the bars", () => {
    const { state, inputs } = run(6, new LiveDrive());
    for (let b = 0; b < 64; b++) {
      expect(inputs.data[DataRow.aux * DATA_WIDTH + Aux.peaks + b]).toBeGreaterThanOrEqual(inputs.data[DataRow.spectrum * DATA_WIDTH + b]);
    }
    expect(state.peaks.length).toBe(64);
  });

  it("sharpens the kick, lifts the hat and never touches the flash uniforms", () => {
    const state = new SoundVisualState();
    state.kick = 0.5;
    state.hat = 0.6;
    state.isSilent = false;
    const filled = new ShaderInputs();
    filled.fill(state, 800, 600);
    const shaped = new ShaderInputs();
    shaped.fill(state, 800, 600);
    new LiveDrive().apply(shaped, state, 1);
    expect(shaped.uniforms[4]).toBeLessThan(filled.uniforms[4]);
    expect(shaped.uniforms[6]).toBeCloseTo(0.96);
    for (let i = 12; i < 16; i++) expect(shaped.uniforms[i]).toBe(filled.uniforms[i]); // fx: flash, chroma, shake
    for (let i = 32; i < 40; i++) expect(shaped.uniforms[i]).toBe(filled.uniforms[i]); // the limited flash and tint
  });

  it("passes silence, calm and a disabled layer through untouched", () => {
    for (const [name, live, options] of [
      ["silence", new LiveDrive(), { silent: true }],
      ["calm", new LiveDrive(), { calm: true }],
      ["disabled", Object.assign(new LiveDrive(), { enabled: false }), {}],
    ] as const) {
      const { state, inputs } = run(2, live, options);
      const reference = new ShaderInputs();
      reference.fill(state, 800, 600);
      expect(Array.from(inputs.uniforms), name).toEqual(Array.from(reference.uniforms));
      expect(inputs.data[DataRow.spectrum * DATA_WIDTH + 10], name).toBe(reference.data[DataRow.spectrum * DATA_WIDTH + 10]);
    }
  });
});
