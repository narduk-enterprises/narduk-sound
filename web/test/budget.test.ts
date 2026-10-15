import { describe, expect, it } from "vitest";
import { FrameGovernor, RENDER_SCALES, isLowEndDevice } from "../src/index.js";

const phone = { devicePixelRatio: 3, hardwareConcurrency: 4, deviceMemory: 2 };
const laptop = { devicePixelRatio: 2, hardwareConcurrency: 10, deviceMemory: 16 };

/** Feeds `seconds` of frames drawn every `interval` ms with `work` ms of script each; returns the end time. */
function run(governor: FrameGovernor, start: number, seconds: number, interval: number, work = 2): number {
  let now = start;
  while (now < start + seconds * 1000) {
    now += interval;
    governor.record(now, work, interval);
  }
  return now;
}

describe("FrameGovernor", () => {
  it("starts a low-end phone at 30 fps, a capped pixel ratio and a reduced scale", () => {
    expect(isLowEndDevice(phone)).toBe(true);
    const g = new FrameGovernor(phone);
    expect(g.decision.fps).toBe(30);
    expect(g.decision.pixelRatio).toBeCloseTo(1.5 * RENDER_SCALES[2]);
  });

  it("starts a laptop at 60 fps and full scale, under the pixel cap", () => {
    const g = new FrameGovernor(laptop);
    expect(g.decision).toEqual({ fps: 60, pixelRatio: 2, scaleStep: 0 });
    const { width, height } = g.backingSize(1920, 1080);
    expect(width * height).toBeLessThanOrEqual(2_400_000 * 1.001);
    expect(width / height).toBeCloseTo(1920 / 1080, 2);
  });

  it("steps the scale down while frames overrun, then halves the rate", () => {
    const g = new FrameGovernor(laptop);
    let now = 0;
    for (let step = 1; step < RENDER_SCALES.length; step++) {
      now = run(g, now, 1, 40);
      expect(g.decision.scaleStep).toBe(step);
    }
    now = run(g, now, 1, 40);
    expect(g.decision.fps).toBe(30);
  });

  it("recovers after a sustained calm, rate first", () => {
    const g = new FrameGovernor(laptop);
    let now = run(g, 0, 5, 40);
    expect(g.decision.fps).toBe(30);
    now = run(g, now, 4.5, 1000 / 30, 1);
    expect(g.decision.fps).toBe(60);
    now = run(g, now, 4.5, 1000 / 60, 1);
    expect(g.decision.scaleStep).toBe(RENDER_SCALES.length - 2);
  });

  it("holds steady on a device that keeps up", () => {
    const g = new FrameGovernor(laptop);
    run(g, 0, 10, 1000 / 60, 3);
    expect(g.decision).toEqual({ fps: 60, pixelRatio: 2, scaleStep: 0 });
  });

  it("draws nothing while hidden and paces a 120 Hz display to 60", () => {
    const g = new FrameGovernor(laptop);
    expect(g.shouldDraw(8.3, 0)).toBe(false);
    expect(g.shouldDraw(16.7, 0)).toBe(true);
    g.setVisible(false);
    expect(g.decision.fps).toBe(0);
    expect(g.shouldDraw(1000, 0)).toBe(false);
  });
});
