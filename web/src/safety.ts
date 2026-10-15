import type { RGB } from "./palette.js";

/**
 * The photosensitivity limits, ported from Sources/NardukSoundVisuals/Intense/IntenseSafety.swift and
 * IntenseLumaWatchdog.swift (WCAG 2.1 SC 2.3.1, Three Flashes or Below Threshold). The main consumer is a children's
 * app, so a full-screen flash is rationed to three a second, never brighter than 0.55 of white and never a hard red;
 * and the finished picture is watched, so any strobe a shader makes on its own is dimmed within a frame or two.
 */
export class FlashLimiter {
  static readonly maxFlashesPerSecond = 3;
  /** A flash is never brighter than this fraction of full white. */
  static readonly maxLevel = 0.55;
  static readonly rise = 0.35;
  static readonly fall = 0.15;

  private readonly onsets = [-Infinity, -Infinity, -Infinity];
  private oldest = 0;
  private open = false;

  /** The flash level to draw for a raw `demand` (0 ... 1) at `now` seconds. `calm` draws none. */
  limit(demand: number, now: number, calm: boolean): number {
    if (calm) {
      this.open = false;
      return 0;
    }
    if (this.open) {
      if (demand < FlashLimiter.fall) this.open = false;
    } else if (demand >= FlashLimiter.rise && now - this.onsets[this.oldest] >= 1.0) {
      this.onsets[this.oldest] = now;
      this.oldest = (this.oldest + 1) % FlashLimiter.maxFlashesPerSecond;
      this.open = true;
    }
    return this.open ? Math.min(Math.max(demand, 0), FlashLimiter.maxLevel) : 0;
  }

  /** The colour to flash for `color`, with green and blue lifted to a third of red so a hard red is never drawn. */
  static safeFlashColor(color: RGB): RGB {
    const lift = color[0] / 3;
    return [color[0], Math.max(color[1], lift), Math.max(color[2], lift)];
  }
}

/**
 * Watches the finished picture's frame-to-frame mean luma (0 ... 1): when it jumps up by more than `jump` more than
 * three times in a second, the stage is dimmed to `dimmedGain` until it has been calm for `hold` seconds.
 */
export class LumaWatchdog {
  static readonly jump = 0.3;
  static readonly maxPerSecond = 3;
  static readonly dimmedGain = 0.25;
  static readonly hold = 1.5;

  private last = -1;
  private lastTime = -Infinity;
  private readonly rises = [-Infinity, -Infinity, -Infinity, -Infinity];
  private next = 0;
  private dimUntil = -Infinity;
  gain = 1;
  isDimming = false;

  /** Feeds the latest measured `luma` at `time` seconds and returns the gain for the next frame. */
  observe(luma: number, time: number): number {
    if (!(time > this.lastTime)) return this.gain;
    const dt = Math.min(time - this.lastTime, 0.25);
    this.lastTime = time;
    if (this.last >= 0 && luma - this.last > LumaWatchdog.jump) {
      this.rises[this.next] = time;
      this.next = (this.next + 1) % 4;
      // Not 1.0: exactly three a second is allowed, and frame times are floats.
      if (time - this.rises[this.next] < 0.99) this.dimUntil = time + LumaWatchdog.hold;
    }
    this.last = luma;
    this.isDimming = time < this.dimUntil;
    const target = this.isDimming ? LumaWatchdog.dimmedGain : 1;
    const rate = this.isDimming ? 30 : 2;
    this.gain += (target - this.gain) * Math.min(1, dt * rate);
    return this.gain;
  }
}

/** What the shaders take beyond the state's envelopes: the rationed flash, the calm scale, the glitch. */
export interface IntenseDrive {
  /** The limited full-screen flash, 0 ... FlashLimiter.maxLevel. */
  flash: number;
  /** 1 normally; `calmIntensity` in calm, scaling motion. */
  intensity: number;
  /** 0 ... 1 glitch strength; 0 in calm. */
  glitch: number;
  /** The red-safe flash tint. */
  flashColor: RGB;
}

export const calmIntensity = 0.4;

/** The drive from the raw envelopes (IntenseDrive.init in Swift). `limiter` carries the flash history. */
export function intenseDrive(
  flashDemand: number,
  glitchDemand: number,
  tint: RGB,
  calm: boolean,
  now: number,
  limiter: FlashLimiter,
): IntenseDrive {
  return {
    flash: limiter.limit(flashDemand, now, calm),
    intensity: calm ? calmIntensity : 1,
    glitch: calm ? 0 : Math.min(Math.max(glitchDemand, 0), 1),
    flashColor: FlashLimiter.safeFlashColor([
      tint[0] + (1 - tint[0]) * 0.5,
      tint[1] + (1 - tint[1]) * 0.5,
      tint[2] + (1 - tint[2]) * 0.5,
    ]),
  };
}
