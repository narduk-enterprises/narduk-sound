/**
 * How fast the visuals may animate (docs/sound-contract.md section 5), ported from SoundRenderBudget.swift, plus the
 * web's own adaptive governor for low-end phones. One place decides when the stage runs, slows or holds still, so no
 * view takes its rate from the display.
 */
export type SoundThermalState = "nominal" | "fair" | "serious" | "critical";

/** The cap on any display: 60 fps looks the same as 120 for soft glows and beat-locked motion. */
const NORMAL_FPS = 60;
/** Thermal pressure or a low-power device: half rate. */
const REDUCED_FPS = 30;

export const SoundRenderBudget = {
  normal: NORMAL_FPS,
  reduced: REDUCED_FPS,

  /** Frames per second for the stage; 0 means paused, holding the last frame. */
  framesPerSecond(isVisible: boolean, thermal: SoundThermalState, lowPowerMode = false): number {
    if (!isVisible) return 0;
    switch (thermal) {
      case "critical":
        return 0;
      case "serious":
        return REDUCED_FPS;
      default:
        return lowPowerMode ? REDUCED_FPS : NORMAL_FPS;
    }
  },

  /** The effective rate for a view that wants at most `cap` fps under the budget `fps`. At least 1 unless paused. */
  rate(fps: number, cap: number = NORMAL_FPS): number {
    return fps <= 0 ? 0 : Math.max(1, Math.min(fps, cap));
  },
};

/** What the governor knows about the device before the first frame. */
export interface DeviceHints {
  devicePixelRatio: number;
  hardwareConcurrency?: number;
  /** `navigator.deviceMemory` in GB, where the browser exposes it. */
  deviceMemory?: number;
  /** `navigator.connection.saveData`. */
  saveData?: boolean;
}

/** A device that starts at the reduced budget: few cores, little memory or a data saver. */
export function isLowEndDevice(hints: DeviceHints): boolean {
  return (
    (hints.hardwareConcurrency !== undefined && hints.hardwareConcurrency <= 4) ||
    (hints.deviceMemory !== undefined && hints.deviceMemory <= 2) ||
    hints.saveData === true
  );
}

/** The render-scale steps the governor walks, applied on top of the capped device pixel ratio. */
export const RENDER_SCALES = [1, 0.85, 0.7, 0.55, 0.42] as const;

export interface GovernorDecision {
  /** Target frames per second (30 or 60; 0 while hidden). */
  fps: number;
  /** Backing-store pixels per CSS pixel. */
  pixelRatio: number;
  /** Index into RENDER_SCALES. */
  scaleStep: number;
}

/**
 * The frame governor: holds the stage to a frame budget on any device. It starts from `SoundRenderBudget` (60 fps, or
 * 30 on a low-end device), caps the backing store at `maxPixels`, and from measured frame times steps the render scale
 * down when frames overrun the budget (then halves the rate as a last resort) and back up after a sustained calm.
 * Pure: fed timestamps, never a clock, so the tests drive it.
 */
export class FrameGovernor {
  /** Frames over budget in a row before stepping down. */
  static readonly overrunFrames = 20;
  /** Seconds under budget before stepping back up. */
  static readonly recoverSeconds = 4;
  /** A frame over this fraction of its budget is an overrun; under `calmFraction` is calm. */
  static readonly overrunFraction = 1.35;
  static readonly calmFraction = 0.75;

  readonly lowEnd: boolean;
  private readonly baseRatio: number;
  private step: number;
  private fps: number;
  private readonly maxFps: number;
  private overruns = 0;
  private calmSince = -1;
  private visible = true;

  constructor(hints: DeviceHints, options: { maxDevicePixelRatio?: number } = {}) {
    this.lowEnd = isLowEndDevice(hints);
    const cap = options.maxDevicePixelRatio ?? (this.lowEnd ? 1.5 : 2);
    this.baseRatio = Math.max(0.5, Math.min(hints.devicePixelRatio || 1, cap));
    this.step = this.lowEnd ? 2 : 0;
    this.maxFps = SoundRenderBudget.framesPerSecond(true, "nominal", this.lowEnd);
    this.fps = this.maxFps;
  }

  get decision(): GovernorDecision {
    return {
      fps: this.visible ? this.fps : 0,
      pixelRatio: this.baseRatio * RENDER_SCALES[this.step],
      scaleStep: this.step,
    };
  }

  /** The backing-store size for a CSS size, also capped at `maxPixels` (2.4 MP, or 1 MP on a low-end device). */
  backingSize(cssWidth: number, cssHeight: number): { width: number; height: number } {
    const maxPixels = this.lowEnd ? 1_000_000 : 2_400_000;
    let ratio = this.decision.pixelRatio;
    const pixels = cssWidth * cssHeight * ratio * ratio;
    if (pixels > maxPixels) ratio *= Math.sqrt(maxPixels / pixels);
    return { width: Math.max(1, Math.round(cssWidth * ratio)), height: Math.max(1, Math.round(cssHeight * ratio)) };
  }

  setVisible(visible: boolean): void {
    this.visible = visible;
    this.overruns = 0;
    this.calmSince = -1;
  }

  /** Whether a display callback at `now` (ms) should draw, given the last drawn frame at `last` (ms). */
  shouldDraw(now: number, last: number): boolean {
    const fps = this.decision.fps;
    if (fps <= 0) return false;
    // Allow a little early: a 60 Hz display's callbacks jitter around 16.7 ms.
    return now - last >= 1000 / fps - 2;
  }

  /**
   * Records a drawn frame at `now` (ms): `intervalMs` since the last drawn frame (what the viewer sees, including the
   * browser's own compositing and GPU time) and `workMs`, the script time from update to draw. Returns true when the
   * decision changed.
   */
  record(now: number, workMs: number, intervalMs: number): boolean {
    if (!this.visible) return false;
    const budget = 1000 / this.fps;
    const over = intervalMs > budget * FrameGovernor.overrunFraction || workMs > budget * 0.8;
    if (over) {
      this.overruns += 1;
      this.calmSince = -1;
    } else {
      this.overruns = Math.max(0, this.overruns - 1);
      const calm = intervalMs < budget * 1.15 && workMs < budget * (1 - FrameGovernor.calmFraction);
      if (!calm) this.calmSince = -1;
      else if (this.calmSince < 0) this.calmSince = now;
    }
    if (this.overruns >= FrameGovernor.overrunFrames) {
      this.overruns = 0;
      if (this.step < RENDER_SCALES.length - 1) {
        this.step += 1;
        return true;
      }
      if (this.fps > SoundRenderBudget.reduced) {
        this.fps = SoundRenderBudget.reduced;
        return true;
      }
      return false;
    }
    if (this.calmSince >= 0 && now - this.calmSince >= FrameGovernor.recoverSeconds * 1000) {
      this.calmSince = now;
      if (this.fps < this.maxFps) {
        this.fps = this.maxFps;
        return true;
      }
      if (this.step > 0) {
        this.step -= 1;
        return true;
      }
    }
    return false;
  }
}
