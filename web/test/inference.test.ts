import { describe, expect, it } from "vitest";
import {
  Instrument,
  SoundAnalyzer,
  SoundMusicInference,
  SoundVisualState,
  SyntheticSource,
  emptyFrame,
  type SoundFrame,
} from "../src/index.js";

/**
 * Behaviour of the music path on audio: a drum machine rendered to samples, run through the analyzer and the
 * inference, must fire the kick, snare and hat lanes, lock near its tempo and drive the visual state. (The numbers
 * Swift produces for the same inference are pinned in contract.test.ts.)
 */
const RATE = 48_000;

/** The window of `n` samples ending at `time`: a kick on every beat, a snare on 2 and 4, a hat on each off-beat 8th. */
function drumWindow(out: Float32Array, time: number, bpm: number): Float32Array {
  const beat = 60 / bpm;
  const n = out.length;
  for (let i = 0; i < n; i++) {
    const s = time - (n - 1 - i) / RATE;
    const beatIndex = Math.floor(s / beat);
    const sinceBeat = s - beatIndex * beat;
    const sinceHalf = (((s + beat / 2) % beat) + beat) % beat;
    const kick = Math.sin(2 * Math.PI * (45 + 110 * Math.exp(-sinceBeat * 35)) * sinceBeat) * Math.exp(-sinceBeat * 16) * 0.8;
    let snare = 0;
    if (beatIndex % 2 === 1) {
      const decay = Math.exp(-sinceBeat * 22);
      for (const hz of [310, 470, 730, 1150, 1700]) snare += Math.sin(2 * Math.PI * hz * s) * decay * 0.12;
    }
    let hat = 0;
    for (const hz of [5200, 7300, 9100, 11700]) hat += Math.sin(2 * Math.PI * hz * s) * Math.exp(-sinceHalf * 90) * 0.06;
    out[i] = Math.max(-1, Math.min(1, kick + snare + hat));
  }
  return out;
}

interface Run {
  inference: SoundMusicInference;
  state: SoundVisualState;
  kicks: number;
  snares: number;
  hats: number;
  /** The state's envelopes, sampled after each frame. */
  stateKick: number;
  stateSnare: number;
  stateHat: number;
  sawBeatPulse: boolean;
  sawRunning: boolean;
  lockedAt: number;
}

function run(window: "apple" | "portable", seconds: number, read: (time: number, into: Float32Array) => Float32Array): Run {
  const analyzer = new SoundAnalyzer(RATE, 1 / 60, window);
  const inference = new SoundMusicInference();
  const state = new SoundVisualState();
  const samples = new Float32Array(SoundAnalyzer.windowSize);
  const frame = emptyFrame();
  const r: Run = {
    inference,
    state,
    kicks: 0,
    snares: 0,
    hats: 0,
    stateKick: 0,
    stateSnare: 0,
    stateHat: 0,
    sawBeatPulse: false,
    sawRunning: false,
    lockedAt: 0,
  };
  for (let k = 1; k <= seconds * 60; k++) {
    const time = k / 60;
    analyzer.analyze(read(time, samples), time, frame);
    const music = inference.update(frame);
    state.update(frame, time, {}, music);
    r.kicks = music.hitCounts[Instrument.kick];
    r.snares = music.hitCounts[Instrument.snare];
    r.hats = music.hitCounts[Instrument.hat];
    r.stateKick = Math.max(r.stateKick, state.kick);
    r.stateSnare = Math.max(r.stateSnare, state.snare);
    r.stateHat = Math.max(r.stateHat, state.hat);
    r.sawBeatPulse ||= state.beatPulse > 0.5;
    r.sawRunning ||= state.isRunning;
    if (r.lockedAt === 0 && inference.isLocked) r.lockedAt = time;
  }
  return r;
}

describe("SoundMusicInference on audio", () => {
  for (const window of ["portable", "apple"] as const) {
    it(`hears kick, snare and hat and locks a 120 BPM drum machine (${window} window)`, () => {
      const bpm = 120;
      const r = run(window, 16, (time, into) => drumWindow(into, time, bpm));
      // 16 s at 120 BPM: 32 beats, a snare on every other one, a hat on every off-beat 8th. A real 43 ms analysis window
      // smears a kick into the snare lane and a snare into the hat lane, so the upper bounds are loose; the lower
      // bounds (every drum is heard) and the kick count (one per beat) are the point.
      expect(r.kicks, "kicks").toBeGreaterThanOrEqual(28);
      expect(r.kicks).toBeLessThanOrEqual(36);
      expect(r.snares, "snares").toBeGreaterThanOrEqual(14);
      expect(r.snares).toBeLessThanOrEqual(64);
      expect(r.hats, "hats").toBeGreaterThanOrEqual(28);
      expect(r.hats).toBeLessThanOrEqual(96);
      const tempo = r.inference.tempoBPM;
      expect(tempo, "tempo").not.toBeNull();
      expect(Math.abs((tempo ?? 0) - bpm), `tempo ${tempo}`).toBeLessThan(3);
      expect(r.lockedAt, "locks within 10 s").toBeLessThan(10);
      // The state follows: the envelopes fire, the beat clock runs and pulses.
      expect(r.stateKick).toBe(1);
      expect(r.stateSnare).toBe(1);
      expect(r.stateHat).toBeGreaterThanOrEqual(0.6);
      expect(r.sawRunning).toBe(true);
      expect(r.sawBeatPulse).toBe(true);
      expect(r.state.secondsPerStep).toBeCloseTo(60 / tempo! / 4, 3);
      expect(r.inference.latest.energy).toBeGreaterThan(0.05);
    });
  }

  it("locks the demo's synthetic source near its tempo", () => {
    const source = new SyntheticSource(124, RATE);
    const r = run("apple", 16, (time, into) => {
      into.set(source.read(time));
      return into;
    });
    expect(r.kicks).toBeGreaterThanOrEqual(28);
    expect(Math.abs((r.inference.tempoBPM ?? 0) - 124)).toBeLessThan(3);
  });

  it("hears nothing in silence and resets to rest", () => {
    const inference = new SoundMusicInference();
    const frame = emptyFrame();
    for (let k = 1; k <= 300; k++) {
      frame.sequence = k;
      frame.time = k / 60;
      inference.update(frame);
    }
    expect(inference.latest.isRunning).toBe(false);
    expect(inference.tempoBPM).toBeNull();
    expect([...inference.latest.hitCounts].every((c) => c === 0)).toBe(true);

    // Loud then reset: as if newly created.
    const loud: SoundFrame = emptyFrame();
    loud.rmsDB = -12;
    loud.spectrum.fill(0.5);
    for (let k = 1; k <= 120; k++) {
      loud.sequence = k;
      loud.time = k / 60;
      loud.spectrum[5] = k % 12 === 0 ? 0.95 : 0.3;
      inference.update(loud);
    }
    expect(inference.latest.isRunning).toBe(true);
    inference.reset();
    expect(inference.latest.isRunning).toBe(false);
    expect(inference.latest.step).toBe(0);
    expect([...inference.latest.hitCounts].every((c) => c === 0)).toBe(true);
  });

  it("returns the same context for a frame it has already heard", () => {
    const inference = new SoundMusicInference();
    const frame = emptyFrame();
    frame.sequence = 1;
    frame.rmsDB = -20;
    const a = inference.update(frame);
    const step = a.step;
    frame.time = 5;
    expect(inference.update(frame).step).toBe(step);
  });

  it("fires nothing when the inference is reset for a new source", () => {
    const inference = new SoundMusicInference();
    const state = new SoundVisualState();
    const frame = emptyFrame();
    frame.rmsDB = -12;
    for (let k = 1; k <= 300; k++) {
      frame.sequence = k;
      frame.time = k / 60;
      frame.spectrum.fill(0.3);
      for (let i = 4; i < 22; i++) frame.spectrum[i] = k % 20 === 0 ? 0.95 : 0.3;
      state.update(frame, k / 60, {}, inference.update(frame));
    }
    expect(inference.latest.hitCounts[Instrument.kick]).toBeGreaterThan(5);
    // Let the envelopes die away on a steady sound.
    for (let k = 301; k <= 420; k++) {
      frame.sequence = k;
      frame.time = k / 60;
      frame.spectrum.fill(0.3);
      state.update(frame, k / 60, {}, inference.update(frame));
    }
    expect(state.kick).toBeLessThan(0.01);
    // A new source: the counters start again at 0, a frame later than the old source's last one.
    inference.reset();
    state.resetMusic();
    frame.sequence = 1;
    frame.time = 7 + 1 / 60;
    state.update(frame, 7 + 1 / 60, {}, inference.update(frame));
    expect(state.kick).toBeLessThan(0.01);
    expect(state.snare).toBeLessThan(0.01);
    expect(state.impact).toBeLessThan(0.01);
    expect(state.shake).toBeLessThan(0.01);
  });

  it("makes the state fire from the counters without replaying a backlog", () => {
    // Counters that jumped before the first frame the state sees are adopted, not fired.
    const state = new SoundVisualState();
    const inference = new SoundMusicInference();
    inference.latest.hitCounts[Instrument.kick] = 7;
    const frame = emptyFrame();
    frame.sequence = 1;
    frame.rmsDB = -30;
    state.update(frame, 1, {}, inference.latest);
    expect(state.kick).toBe(0);
    // Then a kick (and a wrapped counter) fires; a second snare in the same frame fires once.
    inference.latest.hitCounts[Instrument.kick] = 8;
    inference.latest.hitCounts[Instrument.snare] = 0xffffffff;
    frame.sequence = 2;
    state.update(frame, 1 + 1 / 60, {}, inference.latest);
    expect(state.kick).toBeGreaterThan(0.9);
    expect(state.snare).toBeGreaterThan(0.9);
    // Calm gates the flash, shake and chroma triggers.
    expect(state.chroma).toBeGreaterThan(0.8);
    const calm = new SoundVisualState();
    inference.latest.hitCounts[Instrument.snare] = 0;
    frame.sequence = 3;
    calm.update(frame, 1, { calm: true }, inference.latest);
    inference.latest.hitCounts[Instrument.snare] = 1;
    frame.sequence = 4;
    calm.update(frame, 1 + 1 / 60, { calm: true }, inference.latest);
    expect(calm.snare).toBeGreaterThan(0.9);
    expect(calm.chroma).toBe(0);
  });
});
