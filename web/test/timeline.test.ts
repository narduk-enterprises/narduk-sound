import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  AmbientDrift,
  AmbientFeed,
  Instrument,
  LiveDrive,
  ShaderInputs,
  SoundTimelineError,
  SoundTimelinePlayer,
  SoundVisualState,
  TimelineFeed,
  decodeSoundTimeline,
  emptyFrame,
  emptyMusicContext,
  type SoundTimeline,
} from "../src/index.js";

/**
 * The web half of the Swift <-> web timeline contract. `web/fixtures/sound-timeline.json` is written by
 * `WebTimelineFixtureTests` (NSTL bytes recorded from a scripted drum machine, and what the Swift `SoundTimelinePlayer`
 * returns for a script of playback times). These tests decode the same bytes and replay the same times.
 */
interface Detail {
  call: number;
  time: number;
  spectrum: number[];
  chroma: number[];
  peakDB: number;
  rmsDB: number;
  waveform?: number[];
  energy: number;
  wobblePhase: number;
  wobbleCutoff: number;
  secondsPerStep: number;
  phraseProgress: number;
  buildThreshold: number;
  dropThreshold: number;
  stepsPerBar: number;
  stepsPerPhrase: number;
}
const fixture = JSON.parse(readFileSync(new URL("../fixtures/sound-timeline.json", import.meta.url), "utf8")) as {
  nstl: string;
  times: (number | null)[];
  counts: number[][];
  details: Detail[];
};
const nstl = new Uint8Array(Buffer.from(fixture.nstl, "base64"));

function worst(actual: ArrayLike<number>, expected: ArrayLike<number>): number {
  expect(actual.length).toBe(expected.length);
  let off = 0;
  for (let i = 0; i < expected.length; i++) off = Math.max(off, Math.abs(actual[i] - expected[i]));
  return off;
}

/** The container with the JSON header replaced (same payload). */
function withHeader(bytes: Uint8Array, edit: (header: Record<string, unknown>) => void): Uint8Array {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const length = view.getUint32(6, true);
  const header = JSON.parse(new TextDecoder().decode(bytes.subarray(10, 10 + length)));
  edit(header);
  const json = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(10 + json.length + (bytes.length - 10 - length));
  out.set(bytes.subarray(0, 6));
  new DataView(out.buffer).setUint32(6, json.length, true);
  out.set(json, 10);
  out.set(bytes.subarray(10 + length), 10 + json.length);
  return out;
}

describe("decodeSoundTimeline", () => {
  const timeline = decodeSoundTimeline(nstl);

  it("reads the version-1 header and the planar blocks", () => {
    const h = timeline.header;
    expect(h.formatVersion).toBe(1);
    expect(h.trackID).toBe("web-fixture-1");
    expect(h.gridRate).toBe(60);
    expect(h.sampleCount).toBe(570);
    expect(h.waveformPoints).toBe(32);
    expect(h.waveformEvery).toBe(1);
    expect(h.hitLanes).toEqual([Instrument.kick, Instrument.snare, Instrument.hat, Instrument.impact]);
    expect(h.tempoBPM).toBeGreaterThan(100);
    expect(h.inference?.silenceDB).toBeTypeOf("number");
    expect(timeline.spectrum.length).toBe(570 * 64);
    expect(timeline.chroma.length).toBe(570 * 12);
    expect(timeline.position.length).toBe(570);
    expect(timeline.hits.length).toBe(570 * 4);
    expect(timeline.waveform.length).toBe(570 * 32);
    expect(timeline.stepDuration[300]).toBeGreaterThan(0);
  });

  it("accepts an ArrayBuffer and a view with a byte offset", () => {
    const padded = new Uint8Array(nstl.length + 7);
    padded.set(nstl, 7);
    const viaView = decodeSoundTimeline(padded.subarray(7));
    const viaBuffer = decodeSoundTimeline(nstl.slice().buffer);
    for (const other of [viaView, viaBuffer]) {
      expect(other.header).toEqual(timeline.header);
      expect(Array.from(other.position)).toEqual(Array.from(timeline.position));
      expect(Array.from(other.rmsCentiDB)).toEqual(Array.from(timeline.rmsCentiDB));
    }
  });

  it("reads an absent tempo and inference as null (Swift omits a nil optional)", () => {
    const bare = decodeSoundTimeline(
      withHeader(nstl, (h) => {
        delete h.tempoBPM;
        delete h.inference;
      }),
    );
    expect(bare.header.tempoBPM).toBeNull();
    expect(bare.header.inference).toBeNull();
  });

  it("throws the Swift decoding errors", () => {
    const reason = (bytes: Uint8Array) => {
      try {
        decodeSoundTimeline(bytes);
      } catch (error) {
        expect(error).toBeInstanceOf(SoundTimelineError);
        return (error as SoundTimelineError).reason;
      }
      return "no error";
    };
    expect(reason(new TextEncoder().encode("nope, not a timeline"))).toBe("notATimeline");
    expect(reason(new Uint8Array(3))).toBe("notATimeline");
    const newer = nstl.slice();
    newer[4] = 2;
    expect(reason(newer)).toBe("unsupportedVersion");
    expect(reason(withHeader(nstl, (h) => (h.formatVersion = 2)))).toBe("unsupportedVersion");
    expect(reason(nstl.subarray(0, nstl.length - 1))).toBe("truncated");
    expect(reason(nstl.subarray(0, 12))).toBe("truncated");
    const trailing = new Uint8Array(nstl.length + 1);
    trailing.set(nstl);
    expect(reason(trailing)).toBe("inconsistent");
    expect(reason(withHeader(nstl, (h) => (h.hitLanes = [40])))).toBe("inconsistent");
    expect(reason(withHeader(nstl, (h) => (h.waveformPoints = 0)))).toBe("inconsistent");
    expect(reason(withHeader(nstl, (h) => (h.gridRate = 0)))).toBe("inconsistent");
    expect(reason(withHeader(nstl, (h) => delete h.trackID))).toBe("inconsistent");
    const version = (() => {
      try {
        decodeSoundTimeline(newer);
      } catch (error) {
        return (error as SoundTimelineError).version;
      }
    })();
    expect(version).toBe(2);
  });

  it("decodes an empty timeline", () => {
    const empty = decodeSoundTimeline(
      withHeader(nstl.subarray(0, 10 + new DataView(nstl.buffer, nstl.byteOffset).getUint32(6, true)), (h) => {
        h.sampleCount = 0;
        h.duration = 0;
      }),
    );
    expect(empty.header.sampleCount).toBe(0);
    const player = new SoundTimelinePlayer(empty);
    expect(player.input(1).music.isRunning).toBe(false);
  });
});

describe("SoundTimelinePlayer against the Swift player", () => {
  it("returns the Swift counts exactly and the Swift frames and contexts closely", () => {
    const timeline = decodeSoundTimeline(nstl);
    const player = new SoundTimelinePlayer(timeline);
    const lanes = timeline.header.hitLanes;
    expect(fixture.times.length).toBe(fixture.counts.length);
    let farthest = 0;
    let detail = 0;
    fixture.times.forEach((time, call) => {
      const input = player.input(time ?? NaN);
      const { frame, music } = input;
      const section = ["intro", "build", "drop", "breakdown", "drop2"][fixture.counts[call][2]];
      expect([frame.sequence, music.step, fixture.counts[call][2], music.isRunning ? 1 : 0, music.dropQueued ? 1 : 0], `call ${call}`).toEqual(
        fixture.counts[call].slice(0, 5),
      );
      expect(music.section, `call ${call}`).toBe(section);
      expect(lanes.map((lane) => music.hitCounts[lane]), `call ${call} hits`).toEqual(fixture.counts[call].slice(5));
      const expected = fixture.details[detail];
      if (expected && expected.call === call) {
        detail += 1;
        const label = `call ${call}`;
        expect(frame.time, label).toBe(expected.time);
        farthest = Math.max(
          farthest,
          worst(frame.spectrum, expected.spectrum),
          worst(frame.chroma, expected.chroma),
          worst([frame.peakDB, frame.rmsDB], [expected.peakDB, expected.rmsDB]),
          worst(
            [music.energy, music.wobblePhase, music.wobbleCutoff, music.phraseProgress, music.buildThreshold, music.dropThreshold],
            [expected.energy, expected.wobblePhase, expected.wobbleCutoff, expected.phraseProgress, expected.buildThreshold, expected.dropThreshold],
          ),
        );
        expect(music.secondsPerStep, label).toBe(expected.secondsPerStep);
        expect([music.stepsPerBar, music.stepsPerPhrase], label).toEqual([expected.stepsPerBar, expected.stepsPerPhrase]);
        if (expected.waveform) farthest = Math.max(farthest, worst(frame.waveform, expected.waveform));
      }
    });
    expect(detail).toBe(fixture.details.length);
    expect(fixture.details.some((d) => d.waveform)).toBe(true);
    // Swift computes in Float and the port rounds the same operations; 2e-6 leaves room for a last-bit libm difference.
    expect(farthest).toBeLessThan(2e-6);
  });
});

describe("SoundTimelinePlayer", () => {
  const timeline = decodeSoundTimeline(nstl);

  it("asks the same time twice for the same input, and holds the end", () => {
    const player = new SoundTimelinePlayer(timeline);
    const a = player.input(2).frame.sequence;
    expect(player.input(2).frame.sequence).toBe(a);
    expect(player.input(2.01).frame.sequence).toBe(a + 1);
    const end = player.input(timeline.header.duration + 1);
    const sequence = end.frame.sequence;
    expect(end.music.isRunning).toBe(false);
    expect(player.input(timeline.header.duration + 5).frame.sequence).toBe(sequence);
    // Coming back from the end plays again.
    expect(player.input(1).frame.sequence).toBeGreaterThan(sequence);
  });

  it("counts hits on a continuous forward step and none across a seek", () => {
    const player = new SoundTimelinePlayer(timeline);
    const kicks = () => player.input(0).music.hitCounts[Instrument.kick];
    kicks();
    let t = 0;
    for (; t < 3; t += 1 / 60) player.input(t);
    const walked = player.input(t).music.hitCounts[Instrument.kick];
    expect(walked).toBeGreaterThan(4);
    const jumped = player.input(7).music.hitCounts[Instrument.kick];
    expect(jumped).toBe(walked); // a jump forward adds nothing
    const back = player.input(1).music.hitCounts[Instrument.kick];
    expect(back).toBe(walked); // nor does a seek back, and counters never fall
    expect(player.input(1).music.step).toBeLessThan(player.input(7).music.step);
  });

  it("restores a 512-point waveform and keeps it in range", () => {
    const player = new SoundTimelinePlayer(timeline);
    const { waveform } = player.input(3).frame;
    expect(waveform.length).toBe(512);
    expect(Math.max(...waveform)).toBeGreaterThan(0.2);
    expect(Math.min(...waveform)).toBeLessThan(-0.2);
    for (const v of waveform) expect(Math.abs(v)).toBeLessThanOrEqual(1);
  });

  it("survives non-finite and negative times", () => {
    const player = new SoundTimelinePlayer(timeline);
    expect(player.input(NaN).frame.time).toBe(0);
    expect(player.input(-5).frame.time).toBe(0);
    expect(player.input(Infinity).frame.time).toBe(0);
  });
});

describe("AmbientDrift", () => {
  it("breathes near 0.15 with no beat and no hits", () => {
    let low = 1;
    let high = 0;
    for (let t = 0; t < 120; t += 0.5) {
      const e = AmbientDrift.energy(t);
      low = Math.min(low, e);
      high = Math.max(high, e);
    }
    expect(low).toBeGreaterThan(0.15 - 0.035 - 1e-6);
    expect(high).toBeLessThan(0.15 + 0.035 + 1e-6);
    expect(high - low).toBeGreaterThan(0.04);
    const music = AmbientDrift.music(10, emptyMusicContext());
    expect(music.isRunning).toBe(false);
    expect(Array.from(music.hitCounts).every((c) => c === 0)).toBe(true);
    // Swift: energy(at: 0) = 0.15 + 0.035 * (0.45 * sin(1.3))
    expect(AmbientDrift.energy(0)).toBeCloseTo(0.15 + 0.035 * 0.45 * Math.sin(1.3), 6);
  });

  it("draws a dim spectrum weighted to the lows, as a pure function of time", () => {
    const a = AmbientDrift.frame(5, 1, emptyFrame());
    const b = AmbientDrift.frame(5, 2, emptyFrame());
    expect(Array.from(a.spectrum)).toEqual(Array.from(b.spectrum));
    expect(a.spectrum[0]).toBeGreaterThan(a.spectrum[40]);
    expect(Math.max(...a.spectrum)).toBeLessThan(0.3);
    expect(a.rmsDB).toBeLessThan(-20);
    expect(a.peakDB).toBeCloseTo(a.rmsDB + 6, 4);
  });
});

/** What `SoundVisualizer.step` does with a feed, without a canvas. */
function drive(feed: { input(now: number): { frame: ReturnType<typeof emptyFrame>; music: ReturnType<typeof emptyMusicContext> }; liveAmount: number }, state: SoundVisualState, from: number, to: number, record: (state: SoundVisualState, inputs: ShaderInputs, t: number) => void, live = new LiveDrive()) {
  const inputs = new ShaderInputs();
  for (let t = from; t < to; t += 1 / 60) {
    const input = feed.input(t);
    state.update(input.frame, t, {}, input.music);
    inputs.fill(state, 800, 600);
    live.apply(inputs, state, t, feed.liveAmount);
    record(state, inputs, t);
  }
}

describe("TimelineFeed", () => {
  const timeline: SoundTimeline = decodeSoundTimeline(nstl);

  it("replays the timeline at the playhead and drives the state's hits", () => {
    let playhead: number | null = 0;
    const feed = new TimelineFeed(timeline, () => playhead);
    const state = new SoundVisualState();
    let kicks = 0;
    let wasKick = 0;
    drive(feed, state, 0, 4, (s, _i, t) => {
      playhead = t;
      if (s.kick > 0.99 && wasKick < 0.99) kicks += 1;
      wasKick = s.kick;
    });
    expect(kicks).toBeGreaterThanOrEqual(5);
    expect(state.isRunning).toBe(true);
  });

  it("holds when the playhead goes away, fades to the ambient drift, and never fires a hit", () => {
    let playhead: number | null = 0;
    const feed = new TimelineFeed(timeline, () => playhead);
    const state = new SoundVisualState();
    let t = 0;
    const log = { kickMax: 0, impactMax: 0, flashMax: 0 };
    const watch = (s: SoundVisualState) => {
      log.kickMax = Math.max(log.kickMax, s.kick);
    };
    drive(feed, state, 0, 3, (s, _i, now) => {
      playhead = now;
      t = now;
      watch(s);
    });
    expect(feed.liveAmount).toBe(1);
    playhead = null;
    const hitsBefore = Array.from(feed.input(t + 0.01).music.hitCounts);
    let sawHold = false;
    const energies: number[] = [];
    log.kickMax = 0;
    drive(feed, state, t + 0.02, t + 8, (s, _i, now) => {
      if (now < t + 0.5) sawHold = sawHold || s.isRunning === false;
      if (Math.round((now - t) * 60) % 60 === 0) energies.push(s.energy);
      watch(s);
    });
    expect(sawHold).toBe(true);
    // The beat clock stopped at once; after the hold the hits are the same counters and nothing pulses.
    expect(Array.from(feed.input(t + 9).music.hitCounts)).toEqual(hitsBefore);
    expect(log.kickMax).toBeLessThan(0.9);
    expect(feed.liveAmount).toBe(0);
    const ambient = AmbientDrift.energy(t + 9);
    expect(Math.abs(feed.input(t + 9).music.energy - ambient)).toBeLessThan(1e-6);
    expect(state.energy).toBeLessThan(0.3);
    expect(state.isRunning).toBe(false);
  });

  it("fires no burst when a feed is replaced or the playhead returns", () => {
    const state = new SoundVisualState();
    let playhead: number | null = 0;
    const timelineFeed = new TimelineFeed(timeline, () => playhead);
    let t = 0;
    drive(timelineFeed, state, 0, 4, (_s, _i, now) => {
      playhead = now;
      t = now;
    });
    // To the ambient drift: a different feed, so the state adopts its counters (the visualizer calls resetMusic).
    state.resetMusic();
    const ambient = new AmbientFeed();
    let spike = 0;
    drive(ambient, state, t + 1 / 60, t + 3, (s) => {
      spike = Math.max(spike, s.kick, s.snare, s.hat, s.impact);
    });
    expect(spike).toBeLessThan(0.5);
    // And back to a new timeline feed, whose counters start from 0.
    state.resetMusic();
    playhead = 5;
    const again = new TimelineFeed(timeline, () => playhead);
    spike = 0;
    const kicks: number[] = [];
    drive(again, state, t + 3, t + 3.1, (s) => {
      spike = Math.max(spike, s.impact, s.glitch, s.laser);
      kicks.push(s.kick);
    });
    expect(spike).toBeLessThan(0.5);
    expect(kicks[0]).toBeLessThan(0.99);
  });

  it("treats a playhead past the end as unknown", () => {
    const feed = new TimelineFeed(timeline, () => timeline.header.duration + 3);
    const state = new SoundVisualState();
    drive(feed, state, 0, 6, () => {});
    expect(feed.liveAmount).toBe(0);
    expect(state.isRunning).toBe(false);
  });

  it("is ambient from the start when the playhead was never known", () => {
    const feed = new TimelineFeed(timeline, () => null);
    const input = feed.input(1);
    expect(input.music.isRunning).toBe(false);
    expect(input.frame.sequence).toBe(1);
    expect(feed.input(1.02).frame.sequence).toBe(2);
    expect(feed.liveAmount).toBe(0);
  });
});

describe("LiveDrive on a timeline", () => {
  it("stretches the energy of a recorded timeline and leaves the ambient drift alone", () => {
    const timeline = decodeSoundTimeline(nstl);
    const raw: number[] = [];
    const stretched: number[] = [];
    for (const [live, out] of [
      [false, raw],
      [true, stretched],
    ] as const) {
      let playhead = 0;
      const playing = new TimelineFeed(timeline, () => playhead);
      const state = new SoundVisualState();
      const drive2 = new LiveDrive();
      drive2.enabled = live;
      const inputs = new ShaderInputs();
      for (let t = 0; t < 8; t += 1 / 60) {
        playhead = t;
        const input = playing.input(t);
        state.update(input.frame, t, {}, input.music);
        inputs.fill(state, 800, 600);
        drive2.apply(inputs, state, t, playing.liveAmount);
        if (t > 2) out.push(inputs.uniforms[10]);
      }
    }
    // Same inputs, wider drive.
    expect(Math.max(...stretched) - Math.min(...stretched)).toBeGreaterThan(Math.max(...raw) - Math.min(...raw));

    const state = new SoundVisualState();
    const ambient = new AmbientFeed();
    const inputs = new ShaderInputs();
    const liveDrive = new LiveDrive();
    const energies: number[] = [];
    for (let t = 0; t < 30; t += 1 / 60) {
      const input = ambient.input(t);
      state.update(input.frame, t, {}, input.music);
      inputs.fill(state, 800, 600);
      const before = inputs.uniforms[10];
      liveDrive.apply(inputs, state, t, ambient.liveAmount);
      expect(inputs.uniforms[10]).toBe(before);
      energies.push(inputs.uniforms[10]);
    }
    expect(Math.max(...energies)).toBeLessThan(0.3);
  });

  it("mixes by amount", () => {
    const run = (amount: number) => {
      const state = new SoundVisualState();
      const live = new LiveDrive();
      const inputs = new ShaderInputs();
      const player = new SoundTimelinePlayer(decodeSoundTimeline(nstl));
      let last = 0;
      let raw = 0;
      for (let t = 0; t < 6; t += 1 / 60) {
        const input = player.input(t);
        state.update(input.frame, t, {}, input.music);
        inputs.fill(state, 800, 600);
        raw = inputs.uniforms[10];
        live.apply(inputs, state, t, amount);
        last = inputs.uniforms[10];
      }
      return { last, raw };
    };
    const full = run(1);
    const half = run(0.5);
    const none = run(0);
    expect(none.last).toBeCloseTo(none.raw, 6);
    expect(half.last).toBeCloseTo((full.last + full.raw) / 2, 2);
  });
});
