import { SoundAnalyzer } from "./analysis.js";
import type { SampleSource } from "./audio.js";

/**
 * A deterministic test signal as a `SampleSource`, with no audio device and no network: a kick on every beat at
 * `bpm`, a hat on the off-beats and an A minor chord whose loudness swells over eight bars. The browser smoke test and
 * the demo's `?synthetic` mode draw from it; `read(time)` is pure in its time, so a test asks for any instant.
 */
export class SyntheticSource implements SampleSource {
  readonly element = null;
  readonly sampleRate: number;
  private readonly buffer = new Float32Array(SoundAnalyzer.windowSize);
  private paused = true;
  private pausedAt = 0;
  private startedAt = 0;

  constructor(
    private readonly bpm = 124,
    sampleRate = 48_000,
    private readonly clock: () => number = () => performance.now() / 1000,
  ) {
    this.sampleRate = sampleRate;
  }

  get isPaused(): boolean {
    return this.paused;
  }

  async start(): Promise<void> {
    if (!this.paused) return;
    this.startedAt = this.clock() - this.pausedAt;
    this.paused = false;
  }
  async pause(): Promise<void> {
    if (this.paused) return;
    this.pausedAt = this.clock() - this.startedAt;
    this.paused = true;
  }
  async resume(): Promise<void> {
    await this.start();
  }
  async close(): Promise<void> {
    this.paused = true;
  }

  /** The window ending at the source's current time (or at `time` seconds when given). */
  read(time?: number): Float32Array {
    const t = time ?? (this.paused ? this.pausedAt : this.clock() - this.startedAt);
    const n = this.buffer.length;
    const beat = 60 / this.bpm;
    const swell = 0.55 + 0.45 * Math.sin((t / (beat * 32)) * Math.PI * 2);
    for (let i = 0; i < n; i++) {
      const s = t - (n - 1 - i) / this.sampleRate;
      const sinceBeat = ((s % beat) + beat) % beat;
      const sinceHat = (((s + beat / 2) % beat) + beat) % beat;
      const kick = Math.sin(2 * Math.PI * (30 + 90 * Math.exp(-sinceBeat * 30)) * sinceBeat) * Math.exp(-sinceBeat * 22);
      const hat = (hash(Math.floor(s * this.sampleRate)) * 2 - 1) * Math.exp(-sinceHat * 60) * 0.25;
      const chord =
        (Math.sin(2 * Math.PI * 220 * s) + Math.sin(2 * Math.PI * 261.63 * s) + Math.sin(2 * Math.PI * 329.63 * s)) *
        0.09 *
        swell;
      this.buffer[i] = Math.max(-1, Math.min(1, kick * 0.7 + hat + chord));
    }
    return this.buffer;
  }
}

function hash(i: number): number {
  let x = (i ^ 0x9e3779b9) >>> 0;
  x = Math.imul(x ^ (x >>> 16), 0x85ebca6b) >>> 0;
  x = Math.imul(x ^ (x >>> 13), 0xc2b2ae35) >>> 0;
  return ((x ^ (x >>> 16)) >>> 0) / 4294967296;
}
