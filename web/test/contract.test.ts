import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DefaultSoundPaletteProvider,
  FlashLimiter,
  LumaWatchdog,
  SoundAnalyzer,
  SoundRenderBudget,
  SoundVisualState,
  emptyFrame,
  intenseDrive,
  mixedPerceptually,
  sample,
  saturated,
  type SongSection,
  type SoundFrame,
  type SoundPalette,
  type SoundThermalState,
} from "../src/index.js";

/**
 * The web half of the Swift <-> web contract. `web/fixtures/sound-contract.json` is written by the Swift test
 * `WebContractFixtureTests` from the Swift implementation; these tests feed the TypeScript port the same scripted
 * inputs and require the same numbers. The scripts below mirror that test's `signal` and `stateFrame` exactly.
 */
const contract = JSON.parse(readFileSync(new URL("../fixtures/sound-contract.json", import.meta.url), "utf8"));

function expectClose(actual: ArrayLike<number>, expected: ArrayLike<number>, tolerance: number, label: string) {
  expect(actual.length, `${label}: count`).toBe(expected.length);
  let worst = 0;
  let at = -1;
  for (let i = 0; i < expected.length; i++) {
    const off = Math.abs(actual[i] - expected[i]);
    if (off > worst) {
      worst = off;
      at = i;
    }
  }
  expect(worst, `${label}: off by ${worst} at ${at}`).toBeLessThanOrEqual(tolerance);
}

const flat = (p: SoundPalette) => [...p.c0, ...p.c1, ...p.c2];

function signal(frame: number, index: number): number {
  const amplitudes = [0.8, 0.8, 0.5, 0, 0.9, 0.3];
  const g = frame * 800 + index;
  const w = (2 * Math.PI * g) / 48_000;
  const a = amplitudes[frame];
  if (frame >= 4) return a * (0.9 * Math.sin(60 * w) + 0.1 * Math.sin(1_000 * w));
  return a * (0.5 * Math.sin(440 * w) + 0.3 * Math.sin(110 * w) + 0.15 * Math.sin(3_520 * w) + 0.05 * Math.sin(7_040 * w));
}

function stateFrame(k: number): SoundFrame {
  const frame = emptyFrame();
  frame.sequence = Math.floor(k / 2) + 1;
  if (k >= 100 && k < 106) return frame;
  frame.time = k / 60;
  const level = 0.5 + 0.5 * Math.sin(k * 0.11);
  for (let i = 0; i < 64; i++) {
    let value = level * (1 - i / 64) + 0.2 * Math.sin(k * 0.37 + i * 0.5);
    if (k % 24 === 0 && i < 6) value += 0.5;
    frame.spectrum[i] = Math.min(Math.max(value, 0), 1);
  }
  for (let j = 0; j < 512; j++) frame.waveform[j] = level * Math.sin(j * 0.07 + k * 0.9);
  frame.rmsDB = Math.fround(-40 + 30 * level);
  frame.peakDB = frame.rmsDB + 6;
  return frame;
}

describe("the Swift contract fixture", () => {
  it("is version 1", () => {
    expect(contract.version).toBe(1);
  });

  it("analyzes samples into the same frames as SoundAnalyzer", () => {
    const analyzer = new SoundAnalyzer(48_000);
    const samples = new Float32Array(SoundAnalyzer.windowSize);
    contract.analysis.forEach((expected: any, frame: number) => {
      for (let i = 0; i < samples.length; i++) samples[i] = signal(frame, i);
      const out = analyzer.analyze(samples, frame / 60);
      expect(out.sequence).toBe(expected.sequence);
      expectClose(out.spectrum, expected.spectrum, 2e-4, `spectrum ${frame}`);
      expectClose(out.chroma, expected.chroma, 2e-4, `chroma ${frame}`);
      expectClose([out.peakDB, out.rmsDB], [expected.peakDB, expected.rmsDB], 1e-3, `dB ${frame}`);
      expectClose(out.waveform.slice(0, 4), expected.waveformHead, 1e-7, "waveform head");
      expectClose(out.waveform.slice(-4), expected.waveformTail, 1e-7, "waveform tail");
    });
  });

  it("draws the same palettes", () => {
    const provider = new DefaultSoundPaletteProvider();
    const p = contract.palettes;
    expectClose(
      [-0.5, 0, 0.2, 0.5, 0.8, 1, 1.5].flatMap((t) => flat(provider.palette({ scalar: t }))),
      p.scalar.flat(),
      1e-6,
      "scalar",
    );
    const sections: SongSection[] = ["intro", "build", "drop", "breakdown", "drop2"];
    expectClose(sections.flatMap((s) => flat(provider.palette({ section: s }))), p.sections.flat(), 1e-6, "sections");
    const drop = provider.palette({ section: "drop" });
    const breakdown = provider.palette({ section: "breakdown" });
    expectClose([-0.3, 0, 0.25, 0.5, 0.9, 1.7].flatMap((t) => [...sample(drop, Math.fround(t))]), p.samples.flat(), 1e-6, "samples");
    expectClose(flat(saturated(drop, 1.3)), p.saturated, 1e-6, "saturated");
    expectClose(flat(mixedPerceptually(drop, breakdown, 0.5)), p.perceptual, 1e-5, "perceptual");
  });

  it("advances the visual state the same way", () => {
    const state = new SoundVisualState();
    let now = 1.0;
    const checkpoints = contract.state.map((c: any) => c.step);
    let next = 0;
    for (let k = 0; k < 120; k++) {
      state.update(stateFrame(k), now, {
        calm: k >= 60 && k < 75,
        drive: k >= 80 && k < 90 ? 0.9 : undefined,
      });
      if (k === checkpoints[next]) {
        const e = contract.state[next];
        const label = `state at update ${k}`;
        expect(state.isSilent, label).toBe(e.isSilent);
        expect([state.historyHead, state.historyCount], label).toEqual([e.historyHead, e.historyCount]);
        expectClose(state.spectrum, e.spectrum, 1e-4, `${label} spectrum`);
        expectClose(state.peaks, e.peaks, 1e-4, `${label} peaks`);
        expectClose([state.level, state.energy, state.wild, state.kick], [e.level, e.energy, e.wild, e.kick], 1e-4, label);
        expectClose([state.peak, state.rms, state.peakHold], [e.peak, e.rms, e.peakHold], 1e-4, `${label} meters`);
        expectClose([state.beats, state.travel], [e.beats, e.travel], 1e-4, `${label} clock`);
        expectClose(flat(state.palette), e.palette, 1e-4, `${label} palette`);
        next += 1;
      }
      now += k % 5 === 4 ? 1 / 30 : 1 / 60;
    }
    expect(next).toBe(checkpoints.length);
  });

  it("rations flashes the same way", () => {
    const limiter = new FlashLimiter();
    const out = Array.from({ length: 180 }, (_, k) =>
      limiter.limit(Math.floor(k / 4) % 2 === 0 ? 0.9 : 0, k / 60, k >= 120 && k < 150),
    );
    expectClose(out, contract.flashLimiter, 1e-6, "flash limiter");
  });

  it("dims a strobe the same way", () => {
    const watchdog = new LumaWatchdog();
    const out = Array.from({ length: 150 }, (_, k) => {
      const luma = k < 90 ? (Math.floor(k / 3) % 2 === 0 ? 0.9 : 0.1) : 0.2;
      return watchdog.observe(Math.fround(luma), k / 60);
    });
    expectClose(out, contract.lumaWatchdog, 1e-5, "luma watchdog");
  });

  it("makes flash colors red-safe the same way", () => {
    const limiter = new FlashLimiter();
    const tints: [number, number, number][] = [
      [1, 0, 0],
      [0.2, 0.5, 0.9],
      [0.9, 0.1, 0.4],
    ];
    const out = tints.flatMap((t) => [...intenseDrive(1, 0.5, t.map(Math.fround) as never, false, 0, limiter).flashColor]);
    expectClose(out, contract.flashColors.flat(), 1e-6, "flash colors");
  });

  it("budgets frames the same way", () => {
    const out: number[] = [];
    for (const visible of [true, false])
      for (const thermal of ["nominal", "fair", "serious", "critical"] as SoundThermalState[])
        for (const lowPower of [false, true]) out.push(SoundRenderBudget.framesPerSecond(visible, thermal, lowPower));
    expect(out).toEqual(contract.budget);
    expect([0, -3, 1, 24, 60, 120].map((f) => SoundRenderBudget.rate(f))).toEqual(contract.rates);
  });
});
