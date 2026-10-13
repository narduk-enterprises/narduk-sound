import { AmbientDrift } from "./ambient.js";
import { SoundFrameLayout, emptyFrame } from "./frame.js";
import { emptyMusicContext } from "./inference.js";
import { SoundTimelinePlayer, type SoundTimeline, type SoundVisualInput } from "./timeline.js";

/** What `SoundVisualizer` draws from when no audio plays: a `SoundFrame` and `MusicContext` for the frame at `now`. */
export interface InputFeed {
  /** The input for the frame at `now` seconds (the animation clock). The result is the feed's own: rewritten by the next call. */
  input(now: number): SoundVisualInput;
  /** 0 ... 1: how much of `LiveDrive` applies to the frame `input` just returned (0 keeps the state's own drive). */
  readonly liveAmount: number;
}

/** The quiet `AmbientDrift` alone: no timeline, no sound. */
export class AmbientFeed implements InputFeed {
  /** The ambient drift is quiet by design: stretching its breathing to the full range would defeat it. */
  readonly liveAmount = 0;
  private readonly out: SoundVisualInput = { frame: emptyFrame(), music: emptyMusicContext() };
  private sequence = 0;

  input(now: number): SoundVisualInput {
    this.sequence += 1;
    AmbientDrift.frame(now, this.sequence, this.out.frame);
    AmbientDrift.music(now, this.out.music);
    return this.out;
  }
}

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/**
 * A recorded timeline played against a playhead (`SoundVisualizer.setTimeline`).
 *
 * - A finite playhead is looked up in `SoundTimelinePlayer`: what the state sees is the recorded frame and context.
 * - A `null` (or non-finite) playhead means paused or unknown: the last input is held (beat clock stopped, so nothing
 *   pulses), and after `holdSeconds` it crossfades over `fadeSeconds` to `AmbientDrift`, which keeps breathing. A playhead
 *   at or past the timeline's `duration` is treated the same way (the recording ended; the track may go on).
 * - The hit counters are the player's throughout, so switching between replay, hold and ambient never reads as a burst
 *   of hits; a new timeline is a new feed (the visualizer then tells the state to adopt its counters).
 * - Frame `sequence` counts up across all three, so the state never sees an old sequence twice.
 */
export class TimelineFeed implements InputFeed {
  /** Seconds the last input is held after the playhead goes away, before the ambient drift takes over. */
  static readonly holdSeconds = 0.75;
  /** Seconds of the crossfade from the held input to the ambient drift. */
  static readonly fadeSeconds = 3;

  readonly player: SoundTimelinePlayer;
  /** 1 while the timeline plays and through the hold, then fades to 0 with the crossfade to the ambient drift. */
  liveAmount = 1;
  private readonly playhead: () => number | null;
  /** The last replayed input, copied (the player rewrites its own). */
  private readonly held: SoundVisualInput = { frame: emptyFrame(), music: emptyMusicContext() };
  private readonly out: SoundVisualInput = { frame: emptyFrame(), music: emptyMusicContext() };
  private readonly ambient: SoundVisualInput = { frame: emptyFrame(), music: emptyMusicContext() };
  private hasHeld = false;
  private lostAt = -Infinity;
  private sequence = 0;
  private lastPlayerSequence = -1;

  constructor(timeline: SoundTimeline, playhead: () => number | null) {
    this.player = new SoundTimelinePlayer(timeline);
    this.playhead = playhead;
  }

  input(now: number): SoundVisualInput {
    const at = this.playhead();
    const duration = this.player.duration;
    if (at !== null && Number.isFinite(at) && at < duration && this.player.timeline.header.sampleCount > 0) {
      const input = this.player.input(at);
      if (input.frame.sequence !== this.lastPlayerSequence) {
        this.lastPlayerSequence = input.frame.sequence;
        this.sequence += 1;
      }
      copyInput(input, this.held);
      this.held.frame.sequence = this.sequence;
      this.hasHeld = true;
      this.lostAt = -Infinity;
      this.liveAmount = 1;
      return this.held;
    }
    if (this.lostAt === -Infinity) this.lostAt = now;
    this.sequence += 1;
    const frame = this.out.frame;
    const music = this.out.music;
    if (!this.hasHeld) {
      // Nothing was ever played: the ambient drift alone.
      AmbientDrift.frame(now, this.sequence, frame);
      AmbientDrift.music(now, music);
      this.liveAmount = 0;
      return this.out;
    }
    copyInput(this.held, this.out);
    frame.sequence = this.sequence;
    music.isRunning = false;
    const w = Math.min(Math.max((now - this.lostAt - TimelineFeed.holdSeconds) / TimelineFeed.fadeSeconds, 0), 1);
    this.liveAmount = 1 - w;
    if (w > 0) {
      const a = this.ambient;
      AmbientDrift.frame(now, this.sequence, a.frame);
      AmbientDrift.music(now, a.music);
      for (let b = 0; b < SoundFrameLayout.spectrumCount; b++) {
        frame.spectrum[b] = lerp(frame.spectrum[b], a.frame.spectrum[b], w);
      }
      for (let p = 0; p < SoundFrameLayout.chromaCount; p++) frame.chroma[p] *= 1 - w;
      for (let k = 0; k < SoundFrameLayout.waveformCount; k++) frame.waveform[k] *= 1 - w;
      frame.rmsDB = lerp(frame.rmsDB, a.frame.rmsDB, w);
      frame.peakDB = lerp(frame.peakDB, a.frame.peakDB, w);
      music.energy = lerp(music.energy, a.music.energy, w);
      music.wobbleCutoff *= 1 - w;
    }
    return this.out;
  }
}

function copyInput(from: SoundVisualInput, to: SoundVisualInput): void {
  const a = from.frame;
  const b = to.frame;
  b.sequence = a.sequence;
  b.time = a.time;
  b.spectrum.set(a.spectrum);
  b.chroma.set(a.chroma);
  b.waveform.set(a.waveform);
  b.peakDB = a.peakDB;
  b.rmsDB = a.rmsDB;
  const m = from.music;
  const n = to.music;
  n.hitCounts.set(m.hitCounts);
  n.step = m.step;
  n.section = m.section;
  n.energy = m.energy;
  n.wobblePhase = m.wobblePhase;
  n.wobbleCutoff = m.wobbleCutoff;
  n.isRunning = m.isRunning;
  n.secondsPerStep = m.secondsPerStep;
  n.stepsPerBar = m.stepsPerBar;
  n.stepsPerPhrase = m.stepsPerPhrase;
  n.phraseProgress = m.phraseProgress;
  n.buildThreshold = m.buildThreshold;
  n.dropThreshold = m.dropThreshold;
  n.dropQueued = m.dropQueued;
}
