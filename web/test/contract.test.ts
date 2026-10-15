import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DefaultSoundPaletteProvider,
  FlashLimiter,
  LumaWatchdog,
  SoundAnalyzer,
  SoundMusicInference,
  SoundRenderBudget,
  SoundVisualState,
  Instrument,
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

const f32 = Math.fround;

interface DrumOptions {
  bpm?: number;
  rmsDB?: number;
  bed?: number;
  kicks?: boolean;
  snares?: boolean;
  hats?: boolean;
}

/** `DrumFrames.frames` of SoundMusicInferenceTests.swift: bands that rise on each hit and relax at 0.65 / 0.12 a frame. */
function drumFrames(o: DrumOptions, seconds: number, from: number, startTime: number): SoundFrame[] {
  const { bpm = 128, rmsDB = -18, bed = 0.25, kicks = true, snares = true, hats = true } = o;
  const bands = new Float32Array(64).fill(f32(bed));
  const out: SoundFrame[] = [];
  const beat = 60 / bpm;
  for (let i = 0; i < Math.trunc(seconds * 60); i++) {
    const time = i / 60;
    const position = time / beat;
    const beatIndex = Math.floor(position);
    const sinceBeat = (position - beatIndex) * beat;
    const sinceHalf = ((position * 2 - Math.floor(position * 2)) * beat) / 2;
    const kick = kicks && sinceBeat < 0.04;
    const snare = snares && beatIndex % 2 === 1 && sinceBeat < 0.04;
    const hat = hats && sinceHalf < 0.02;
    for (let b = 0; b < 64; b++) {
      let target = f32(bed);
      if (kick && b >= 4 && b < 22) target = f32(0.9);
      if (snare && b >= 22 && b < 44) target = Math.max(target, f32(0.8));
      if (hat && b >= 46) target = Math.max(target, f32(0.7));
      bands[b] = f32(bands[b] + f32(f32(target - bands[b]) * f32(target > bands[b] ? 0.65 : 0.12)));
    }
    const frame = emptyFrame();
    frame.sequence = from + i;
    frame.time = startTime + time;
    frame.spectrum.set(bands);
    frame.rmsDB = f32(rmsDB);
    frame.peakDB = f32(f32(rmsDB) + 6);
    out.push(frame);
  }
  return out;
}

function silenceFrames(seconds: number, from: number, startTime: number): SoundFrame[] {
  return Array.from({ length: Math.trunc(seconds * 60) }, (_, i) => {
    const frame = emptyFrame();
    frame.sequence = from + i;
    frame.time = startTime + i / 60;
    return frame;
  });
}

/** `WebContractFixtureTests.drumScript`: eight loud seconds at 128 BPM, a quiet breakdown, silence, drums again. */
function drumScript(): SoundFrame[] {
  return [
    ...drumFrames({ bpm: 128, rmsDB: -12 }, 8, 1, 0),
    ...drumFrames({ bpm: 128, rmsDB: -34, bed: 0.1, kicks: false, snares: false, hats: false }, 5, 481, 8),
    ...silenceFrames(3, 781, 13),
    ...drumFrames({ bpm: 128, rmsDB: -18 }, 6, 961, 16),
  ];
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

  // The fixture is written on Linux, where SpectrumAnalyzer's window is 0.5 (1 - cos): analyze with that one.
  it("analyzes samples into the same frames as SoundAnalyzer", () => {
    const analyzer = new SoundAnalyzer(48_000, 1 / 60, "portable");
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

  // On Apple, vDSP_HANN_NORM is 0.8165 (1 - cos). The macOS Swift run of this fixture (narduk-sound#66, CI run
  // 38324435057) measured the worst spectrum differences below against the Linux numbers; the web's default
  // "apple" window reproduces them.
  it("reads Apple's hotter window the way vDSP does", () => {
    const portable = new SoundAnalyzer(48_000, 1 / 60, "portable");
    const apple = new SoundAnalyzer(48_000);
    const samples = new Float32Array(SoundAnalyzer.windowSize);
    // Sequences 1, 2 and 3 (frames 0, 1 and 2).
    const measuredOnMacOS = [0.0385, 0.0519, 0.0566];
    measuredOnMacOS.forEach((worst, frame) => {
      for (let j = 0; j < samples.length; j++) samples[j] = signal(frame, j);
      const a = apple.analyze(samples, frame / 60).spectrum;
      const p = portable.analyze(samples, frame / 60).spectrum;
      const diff = Math.max(...a.map((v, k) => Math.abs(v - p[k])));
      expect(diff, `frame ${frame}`).toBeCloseTo(worst, 3);
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

  // Events (the frame a lane fired on, the tempo lock, each section change) are compared exactly; the running values
  // with the Float-versus-double tolerance of the other checkpoints.
  it("hears the scripted drum machine the way SoundMusicInference does, and the state follows", () => {
    const m = contract.music;
    const inference = new SoundMusicInference();
    const state = new SoundVisualState();
    const kicks: number[] = [];
    const snares: number[] = [];
    const hats: number[] = [];
    const impacts: number[] = [];
    const sections: { sequence: number; section: string }[] = [];
    let lock = 0;
    let section = "intro";
    let last = [0, 0, 0, 0];
    let next = 0;
    const frames = drumScript();
    expect(frames.length).toBe(m.frames);
    for (const frame of frames) {
      const music = inference.update(frame);
      const hits = [Instrument.kick, Instrument.snare, Instrument.hat, Instrument.impact].map((lane) => music.hitCounts[lane]);
      if (hits[0] !== last[0]) kicks.push(frame.sequence);
      if (hits[1] !== last[1]) snares.push(frame.sequence);
      if (hits[2] !== last[2]) hats.push(frame.sequence);
      if (hits[3] !== last[3]) impacts.push(frame.sequence);
      last = hits;
      if (lock === 0 && inference.isLocked) lock = frame.sequence;
      if (music.section !== section) {
        section = music.section;
        sections.push({ sequence: frame.sequence, section });
      }
      state.update(frame, frame.time + 1, { calm: frame.sequence >= 1000 && frame.sequence < 1100 }, music);
      if (frame.sequence % 40 !== 20) continue;
      const i = m.inference[next];
      const e = m.state[next];
      const label = `frame ${frame.sequence}`;
      expect(frame.sequence, label).toBe(i.sequence);
      expect(hits, label).toEqual(i.hits);
      expect([music.step, music.section, music.isRunning, music.dropQueued], label).toEqual([i.step, i.section, i.isRunning, i.dropQueued]);
      expectClose(
        [music.energy, music.wobblePhase, music.wobbleCutoff, music.phraseProgress, music.secondsPerStep],
        [i.energy, i.wobblePhase, i.wobbleCutoff, i.phraseProgress, i.secondsPerStep],
        2e-3,
        `${label} inference`,
      );
      expect(Math.abs((inference.tempoBPM ?? 0) - i.tempoBPM), `${label} tempo`).toBeLessThan(0.05);

      expect(frame.sequence, label).toBe(e.sequence);
      expect([state.section, state.isRunning, state.dropQueued], label).toEqual([e.section, e.isRunning, e.dropQueued]);
      expectClose(
        [state.kick, state.snare, state.hat, state.glitch, state.laser, state.impact, state.flash, state.shake, state.chroma],
        e.envelopes,
        2e-3,
        `${label} envelopes`,
      );
      expectClose(
        [
          state.energy,
          state.wild,
          state.dropAmount,
          state.beatPulse,
          state.phraseProgress,
          state.wobblePhase,
          state.wobbleCutoff,
          state.shakeOffset[0],
          state.shakeOffset[1],
        ],
        e.motion,
        2e-3,
        `${label} motion`,
      );
      expectClose([state.beats, state.travel], e.clock, 2e-3, `${label} clock`);
      expectClose(flat(state.palette), e.palette, 2e-3, `${label} palette`);
      next += 1;
    }
    expect(next).toBe(m.inference.length);
    expect(kicks, "kick frames").toEqual(m.kickFrames);
    expect(snares, "snare frames").toEqual(m.snareFrames);
    expect(hats, "hat frames").toEqual(m.hatFrames);
    expect(impacts, "impact frames").toEqual(m.impactFrames);
    expect(lock, "tempo lock frame").toBe(m.lockSequence);
    expect(sections, "section changes").toEqual(m.sectionChanges);
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
