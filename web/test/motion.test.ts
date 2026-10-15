import { describe, expect, it } from "vitest";
import { SoundAnalyzer, SoundVisualState, SyntheticSource, emptyFrame, isStatic } from "../src/index.js";

describe("motion", () => {
  it("is static with reduced motion unless the viewer asks for full motion", () => {
    expect(isStatic("auto", true)).toBe(true);
    expect(isStatic("auto", false)).toBe(false);
    expect(isStatic("full", true)).toBe(false);
    expect(isStatic("static", false)).toBe(true);
  });
});

describe("the synthetic source through the analysis and state", () => {
  it("moves the spectrum, fires the kick and stays deterministic", () => {
    const run = () => {
      const source = new SyntheticSource(120, 48_000, () => 0);
      const analyzer = new SoundAnalyzer(source.sampleRate);
      const state = new SoundVisualState();
      const frame = emptyFrame();
      let kicks = 0;
      let lastKick = 0;
      for (let k = 0; k < 240; k++) {
        const t = k / 60;
        state.update(analyzer.analyze(source.read(t), t, frame), t);
        if (state.kick > lastKick + 0.3) kicks += 1;
        lastKick = state.kick;
      }
      return { kicks, spectrum: Array.from(state.spectrum), level: state.level };
    };
    const a = run();
    expect(a.kicks).toBeGreaterThanOrEqual(4);
    expect(a.level).toBeGreaterThan(0.3);
    expect(Math.max(...a.spectrum)).toBeGreaterThan(0.4);
    expect(run()).toEqual(a);
  });
});
