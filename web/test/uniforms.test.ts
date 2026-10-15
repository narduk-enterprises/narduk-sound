import { describe, expect, it } from "vitest";
import { Aux, DATA_WIDTH, DataRow, ShaderInputs, SoundVisualState, emptyFrame, scopeTrigger } from "../src/index.js";

describe("ShaderInputs", () => {
  it("finds the scope's rising zero crossing", () => {
    const wave = new Float32Array(512);
    for (let i = 0; i < 512; i++) wave[i] = Math.sin((i - 37) * 0.1);
    expect(scopeTrigger(wave)).toBe(37);
    expect(scopeTrigger(new Float32Array(512))).toBe(0);
    expect(scopeTrigger(new Float32Array(100))).toBe(0);
  });

  it("packs the state as the Metal renderer does", () => {
    const state = new SoundVisualState();
    const frame = emptyFrame();
    frame.sequence = 1;
    frame.rmsDB = -12;
    frame.peakDB = -6;
    for (let i = 0; i < 64; i++) frame.spectrum[i] = i / 64;
    for (let i = 0; i < 512; i++) frame.waveform[i] = Math.sin(i * 0.2);
    state.update(frame, 1);
    const inputs = new ShaderInputs();
    inputs.fill(state, 800, 600);
    const u = inputs.uniforms;
    expect([u[0], u[1]]).toEqual([800, 600]);
    expect(u[2]).toBeCloseTo(1);
    expect(u[10]).toBeCloseTo(state.energy);
    expect([u[20], u[21], u[22]].map((x) => Math.fround(x))).toEqual([...state.palette.c0].map((x) => Math.fround(x)));
    expect(u[34]).toBe(1); // intensity
    expect(u[39]).toBe(0); // not calm
    const d = inputs.data;
    expect(d[DataRow.spectrum * DATA_WIDTH + 63]).toBeCloseTo(state.spectrum[63], 6);
    expect(d[DataRow.waveform * DATA_WIDTH + 100]).toBeCloseTo(state.waveform[100], 6);
    expect(d[DataRow.aux * DATA_WIDTH + Aux.peaks + 10]).toBeCloseTo(state.peaks[10], 6);
    expect(d[DataRow.aux * DATA_WIDTH + Aux.silent]).toBe(0);
    expect(d[DataRow.aux * DATA_WIDTH + Aux.scopeTrigger]).toBe(scopeTrigger(state.waveform));
    // History: only the newest trace exists; it is the trace after the trigger, every third sample.
    const trigger = scopeTrigger(state.waveform);
    const h = DataRow.history * DATA_WIDTH;
    expect(d[h + 5]).toBeCloseTo(state.waveform[trigger + 15], 6);
    expect(d[h + Aux.historyPoints + 5]).toBe(0);
  });

  it("never flashes more than three times a second, nor at all in calm", () => {
    const state = new SoundVisualState();
    const inputs = new ShaderInputs();
    let starts = 0;
    let last = 0;
    const frame = emptyFrame();
    for (let k = 0; k < 120; k++) {
      // A source that demands a full flash on every other frame.
      state.flash = k % 2 === 0 ? 1 : 0;
      state.time = k / 60;
      inputs.fill(state, 10, 10);
      const flash = inputs.uniforms[32];
      expect(flash).toBeLessThanOrEqual(Math.fround(0.55));
      if (flash > 0 && last === 0) starts += 1;
      last = flash;
    }
    expect(starts).toBeLessThanOrEqual(6);
    state.update(frame, 10, { calm: true });
    state.flash = 1;
    inputs.fill(state, 10, 10);
    expect(inputs.uniforms[32]).toBe(0);
    expect(inputs.uniforms[34]).toBeCloseTo(0.4);
  });
});
