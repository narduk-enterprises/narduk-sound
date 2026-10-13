import { SoundFrameLayout, type SoundFrame } from "./frame.js";
import type { SongSection } from "./palette.js";

/**
 * The lanes of `HitCounters` (Sources/NardukMusicCore/MusicContext.swift): a stable index per instrument, never
 * renumbered. Only the lanes inference counts or the visual state reacts to are named here.
 */
export const Instrument = {
  kick: 0,
  snare: 1,
  hat: 2,
  openHat: 3,
  glitch: 6,
  scratch: 7,
  laser: 8,
  impact: 12,
} as const;

/** Lanes in a `HitCounters` (`HitCounters.laneCount`). */
export const HIT_LANE_COUNT = 32;

/**
 * The subset of `MusicContext` (NardukMusicCore) that `SoundMusicInference` produces and `SoundVisualState` reads.
 * Notes, the key and the held-note set are absent: inference never fills them (the visualizers read the analysis
 * chroma). `hitCounts` is monotonic per lane and wraps at 2^32; a consumer keeps the value it last saw and takes the
 * wrapping difference. `SoundMusicInference.update` returns one object it rewrites in place, so a consumer that wants a
 * snapshot copies `hitCounts` (the state does).
 */
export interface MusicContext {
  hitCounts: Uint32Array;
  /** Conductor step, 16ths. */
  step: number;
  section: SongSection;
  /** Conductor energy 0 ... 1. */
  energy: number;
  wobblePhase: number;
  wobbleCutoff: number;
  isRunning: boolean;
  /** Seconds per 16th (60 / bpm / 4). */
  secondsPerStep: number;
  stepsPerBar: number;
  stepsPerPhrase: number;
  phraseProgress: number;
  buildThreshold: number;
  dropThreshold: number;
  dropQueued: boolean;
}

/** A `MusicContext` at rest (Swift's `MusicContext()`). */
export function emptyMusicContext(): MusicContext {
  return {
    hitCounts: new Uint32Array(HIT_LANE_COUNT),
    step: 0,
    section: "intro",
    energy: 0,
    wobblePhase: 0,
    wobbleCutoff: 0,
    isRunning: false,
    secondsPerStep: 60 / 140 / 4,
    stepsPerBar: 16,
    stepsPerPhrase: 128,
    phraseProgress: 0,
    buildThreshold: 0.55,
    dropThreshold: 0.4,
    dropQueued: false,
  };
}

const f = Math.fround;

/** Swift's `rounded()`: to nearest, ties away from zero (`Math.round` rounds ties toward +infinity). */
function roundAway(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

/** An onset detector over one range of bands, counted on one instrument lane. */
interface Lane {
  readonly instrument: number;
  readonly from: number;
  readonly to: number;
  /** The least flux that can be an onset, in band units (0 ... 1 per band). */
  readonly floor: number;
  /** How many running deviations above the running mean an onset must rise. */
  readonly sigma: number;
  /** Two onsets closer than this are one. */
  readonly refractory: number;
  /** Its weight in the onset strength the tempo is measured on. */
  readonly weight: number;
  mean: number;
  deviation: number;
  lastFlux: number;
  lastOnset: number;
  /** The flux above the running mean this frame, 0 when below it. */
  strength: number;
}

function lane(instrument: number, from: number, to: number, floor: number, sigma: number, refractory: number, weight: number): Lane {
  return {
    instrument,
    from,
    to,
    floor: f(floor),
    sigma: f(sigma),
    refractory,
    weight: f(weight),
    mean: 0,
    deviation: 0,
    lastFlux: 0,
    lastOnset: -Infinity,
    strength: 0,
  };
}

function resetLane(l: Lane): void {
  l.mean = 0;
  l.deviation = 0;
  l.lastFlux = 0;
  l.lastOnset = -Infinity;
  l.strength = 0;
}

/**
 * Hears the music in a `SoundFrame` stream that has no conductor (an `<audio>` element, a stream, a file) and says what
 * it hears as a `MusicContext`: the web port of `SoundMusicInference`
 * (Sources/NardukSoundVisuals/SoundMusicInference.swift), line for line, so a stream draws the way a recording does in
 * the Swift visualizers (docs/sound-contract.md section 2).
 *
 * - **Hits.** Spectral flux (the half-wave rectified rise of the bands since the last frame) in three ranges, about
 *   30 ... 200 Hz, 200 Hz ... 2 kHz and 2.4 ... 16 kHz, against an adaptive threshold (a running mean plus a multiple
 *   of the running deviation) with a refractory time per lane, counted on the `kick`, `snare` and `hat` lanes.
 * - **Tempo and beat.** The onset strength is resampled onto a 50 Hz grid; every half second its autocorrelation over
 *   60 ... 200 BPM picks a period, scored with its double- and quadruple-time subdivisions, averaged over the last
 *   several estimates and weighted gently toward 130 BPM. The clock locks when four estimates in a row agree and
 *   leaves a locked tempo only for one that scores clearly higher. Kick onsets pull the beat phase.
 * - **Energy and section.** A fast loudness against a slow ceiling and floor, plus onset density, gives `energy`; energy
 *   held near the loudest the song has reached is a drop (`drop` and `drop2` alternate, with an `impact` hit on entry),
 *   a fall well below it a breakdown and rising energy a build.
 *
 * The scalar accumulators are Float in Swift; they are rounded with `Math.fround` here so the two sides cross the same
 * thresholds on the same frame. The band spectrum must come from the same window as the Swift side read (the web's
 * `SoundAnalyzer` "apple" window matches Apple; "portable" matches the Linux fixture). Every buffer is allocated in the
 * constructor; `update` never allocates. Own one per source.
 */
export class SoundMusicInference {
  /** The onset-strength grid the tempo is measured on, and how much of it (8 s). */
  static readonly gridRate = 50;
  static readonly gridCount = 400;
  static readonly minBPM = 60;
  static readonly maxBPM = 200;
  /** The tempo the clock runs at before a lock (the engine's default). */
  static readonly defaultBPM = 140;
  /** The share of the heard `loudness` published as the context's `energy`. */
  static readonly contextEnergyScale = f(0.45);
  /** Below this RMS the source is silent: the clock stops and the section rests. */
  static readonly silenceDB = f(-65);

  private static readonly tempoInterval = 0.5;
  private static readonly minLag = Math.trunc((50 * 60) / 200); // 15
  private static readonly maxLag = Math.trunc((50 * 60) / 60); // 50
  /** The shortest lag correlated: a quadruple-time subdivision of the fastest tempo. */
  private static readonly subdivisionLag = Math.trunc(SoundMusicInference.minLag / 4);
  private static readonly agreementsToLock = 4;
  private static readonly agreementsToSwitch = 8;
  private static readonly staleGap = 0.5;

  private readonly kick = lane(Instrument.kick, 4, 22, 0.012, 1.8, 0.11, 1);
  private readonly snare = lane(Instrument.snare, 22, 44, 0.01, 2.0, 0.11, 0.7);
  private readonly hat = lane(Instrument.hat, 46, 64, 0.008, 1.3, 0.05, 0.3);

  private readonly previousBands = new Float32Array(SoundFrameLayout.spectrumCount);
  private readonly grid = new Float32Array(SoundMusicInference.gridCount);
  private readonly window = new Float32Array(SoundMusicInference.gridCount);
  private readonly correlation = new Float32Array(SoundMusicInference.maxLag + 1);
  /** The correlation averaged over the last several estimates (~10 s). */
  private readonly averaged = new Float32Array(SoundMusicInference.maxLag + 1);
  private estimates = 0;
  private gridHead = 0;
  private gridTime = -Infinity;
  private gridFilled = 0;
  private strength = 0;
  private lastTempoTime = -Infinity;

  private lastSequence = 0;
  private lastTime = 0;
  private readonly counts = new Uint32Array(HIT_LANE_COUNT);

  // Tempo and clock.
  private bpm = SoundMusicInference.defaultBPM;
  private candidateBPM = 0;
  private agreements = 0;
  private locked = false;
  private stepPosition = 0;
  private lastStep = 0;
  private lockTime = -Infinity;

  // Energy and section.
  private heard = false;
  private loud = SoundFrameLayout.silenceDB as number;
  private ceiling = SoundFrameLayout.silenceDB as number;
  private floorDB = SoundFrameLayout.silenceDB as number;
  private density = 0;
  private energySlow = 0;
  private energyPeak = 0;
  private _level = 0;
  private _levelPeak = 0;
  private _levelSlow = 0;
  private heardSince = -Infinity;
  private midLevel = 0;
  private silentSince = -Infinity;
  private highSince = -Infinity;
  private midSince = -Infinity;
  private lowSince = -Infinity;
  private sectionSince = -Infinity;
  private dropsEntered = 0;
  /** The loudness peak when the current drop began: a drop much louder than it is a new drop. */
  private dropEntryPeak = 0;
  private energy = 0;
  private section: SongSection = "intro";

  /** The last context `update` produced (rewritten in place by the next one). */
  readonly latest: MusicContext = emptyMusicContext();

  /** The tempo the clock runs at, in BPM; null until a tempo is locked. */
  get tempoBPM(): number | null {
    return this.locked ? this.bpm : null;
  }
  /** True while the beat clock follows a measured tempo. */
  get isLocked(): boolean {
    return this.locked;
  }
  /** The loudness and onset density heard, 0 ... 1: what drives the sections (not the context's `energy`). */
  get loudness(): number {
    return this.energy;
  }
  /** Loudness alone, smoothed like `energy`; sections follow it. */
  get level(): number {
    return this._level;
  }

  /** Forgets everything heard, as if newly created. */
  reset(): void {
    resetLane(this.kick);
    resetLane(this.snare);
    resetLane(this.hat);
    this.previousBands.fill(0);
    this.grid.fill(0);
    this.averaged.fill(0);
    this.gridHead = 0;
    this.gridTime = -Infinity;
    this.gridFilled = 0;
    this.estimates = 0;
    this.strength = 0;
    this.lastTempoTime = -Infinity;
    this.lastSequence = 0;
    this.lastTime = 0;
    this.counts.fill(0);
    this.bpm = SoundMusicInference.defaultBPM;
    this.candidateBPM = 0;
    this.agreements = 0;
    this.locked = false;
    this.stepPosition = 0;
    this.lastStep = 0;
    this.lockTime = -Infinity;
    this.heard = false;
    this.loud = SoundFrameLayout.silenceDB;
    this.ceiling = SoundFrameLayout.silenceDB;
    this.floorDB = SoundFrameLayout.silenceDB;
    this.density = 0;
    this.energySlow = 0;
    this.energyPeak = 0;
    this._level = 0;
    this._levelPeak = 0;
    this._levelSlow = 0;
    this.heardSince = -Infinity;
    this.midLevel = 0;
    this.silentSince = -Infinity;
    this.highSince = -Infinity;
    this.midSince = -Infinity;
    this.lowSince = -Infinity;
    this.sectionSince = -Infinity;
    this.dropsEntered = 0;
    this.dropEntryPeak = 0;
    this.energy = 0;
    this.section = "intro";
    const l = this.latest;
    l.hitCounts.fill(0);
    l.step = 0;
    l.section = "intro";
    l.energy = 0;
    l.wobblePhase = 0;
    l.wobbleCutoff = 0;
    l.isRunning = false;
    l.secondsPerStep = 60 / 140 / 4;
    l.stepsPerBar = 16;
    l.stepsPerPhrase = 128;
    l.phraseProgress = 0;
    l.buildThreshold = 0.55;
    l.dropThreshold = 0.4;
    l.dropQueued = false;
  }

  /** Hears `frame` and returns the context so far. A frame already heard (same `sequence`) returns `latest` unchanged. */
  update(frame: SoundFrame): MusicContext {
    if (frame.sequence === this.lastSequence) return this.latest;
    const now = frame.time;
    const first = this.lastSequence === 0;
    const stale = first || now - this.lastTime > SoundMusicInference.staleGap || now < this.lastTime;
    const dt = stale ? 1 / 60 : Math.min(Math.max(now - this.lastTime, 0.001), 0.1);
    this.lastSequence = frame.sequence;
    this.lastTime = now;
    if (first) {
      this.sectionSince = now;
      this.gridTime = now;
    }

    const silent = f(frame.rmsDB) < SoundMusicInference.silenceDB;
    if (silent) {
      if (this.silentSince === -Infinity) this.silentSince = now;
    } else {
      this.silentSince = -Infinity;
    }
    const resting = silent && now - this.silentSince > 1.0;

    this.hear(frame, now, dt, stale, silent);
    this.feedGrid(now);
    if (now - this.lastTempoTime >= SoundMusicInference.tempoInterval && this.gridFilled >= Math.trunc((SoundMusicInference.gridCount * 3) / 8)) {
      this.lastTempoTime = now;
      this.estimateTempo();
    }
    this.advanceClock(dt, resting);
    this.updateEnergy(frame, f(dt), silent, resting);
    this.updateSection(now, resting);

    const running = this.heard && !resting;
    const secondsPerStep = 60 / this.bpm / 4;
    const beats = this.stepPosition / 4;
    const phase = f(beats - Math.floor(beats));
    // `energy` is the conductor's slot in the context: the share `contextEnergyScale` of the heard loudness (see the
    // Swift `update`), which the sections keep reading in full.
    const l = this.latest;
    l.step = this.lastStep;
    l.section = this.section;
    l.energy = f(this.energy * SoundMusicInference.contextEnergyScale);
    l.wobblePhase = f((phase * 2) % 1);
    l.wobbleCutoff = this.midLevel;
    l.isRunning = running;
    l.secondsPerStep = secondsPerStep;
    l.stepsPerBar = 16;
    l.stepsPerPhrase = 128;
    l.phraseProgress = f((this.lastStep % 128) / 128);
    l.buildThreshold = f(0.55);
    l.dropThreshold = f(0.4);
    l.dropQueued = this.section === "build" && this.energy > f(0.55);
    l.hitCounts.set(this.counts);
    return l;
  }

  // MARK: Onsets

  private hear(frame: SoundFrame, now: number, dt: number, stale: boolean, silent: boolean): void {
    const previous = this.previousBands;
    const bands = frame.spectrum;
    const count = Math.min(bands.length, previous.length);
    if (stale) for (let i = 0; i < count; i++) previous[i] = bands[i];
    const kickFlux = SoundMusicInference.flux(bands, previous, this.kick, count);
    const snareFlux = SoundMusicInference.flux(bands, previous, this.snare, count);
    const hatFlux = SoundMusicInference.flux(bands, previous, this.hat, count);
    for (let i = 0; i < count; i++) previous[i] = bands[i];
    let sum = 0;
    const upper = Math.min(40, count);
    for (let i = 16; i < upper; i++) sum = f(sum + bands[i]);
    const mid = f(sum / 24);
    this.midLevel = f(this.midLevel + f(f(mid - this.midLevel) * f(Math.min(1, dt * 8))));

    let fired = 0;
    if (SoundMusicInference.detect(this.kick, kickFlux, now, dt, silent)) {
      this.counts[Instrument.kick] += 1;
      fired += 1;
      this.pullBeat();
    }
    if (SoundMusicInference.detect(this.snare, snareFlux, now, dt, silent)) {
      this.counts[Instrument.snare] += 1;
      fired += 1;
    }
    if (SoundMusicInference.detect(this.hat, hatFlux, now, dt, silent)) {
      this.counts[Instrument.hat] += 1;
      fired += 0.5;
    }
    this.strength = f(f(f(this.kick.strength * this.kick.weight) + f(this.snare.strength * this.snare.weight)) + f(this.hat.strength * this.hat.weight));
    // Onsets per second, smoothed over ~2 s.
    const fdt = f(dt);
    this.density = f(this.density + f(f(f(fired / fdt) - this.density) * f(Math.min(1, dt / 2))));
  }

  /** Mean half-wave rectified rise over the lane's bands since `previous`. */
  private static flux(bands: Float32Array, previous: Float32Array, l: Lane, count: number): number {
    const upper = Math.min(l.to, count);
    if (!(l.from < upper)) return 0;
    let sum = 0;
    for (let i = l.from; i < upper; i++) sum = f(sum + Math.max(0, f(bands[i] - previous[i])));
    return f(sum / (upper - l.from));
  }

  /** Updates the lane's running statistics with `flux` and returns whether it is an onset. */
  private static detect(l: Lane, flux: number, now: number, dt: number, silent: boolean): boolean {
    const threshold = f(f(l.floor + l.mean) + f(l.sigma * l.deviation));
    const rising = flux > l.lastFlux;
    const fires = !silent && flux > threshold && rising && now - l.lastOnset >= l.refractory;
    l.strength = Math.max(0, f(flux - l.mean));
    // The baseline follows the signal over ~1.5 s, but an onset itself only nudges it.
    const alpha = f(f(Math.min(1, dt / 1.5)) * (flux > threshold ? 0.25 : 1));
    l.mean = f(l.mean + f(f(flux - l.mean) * alpha));
    l.deviation = f(l.deviation + f(f(Math.abs(f(flux - l.mean))) - l.deviation) * alpha);
    l.lastFlux = flux;
    if (fires) l.lastOnset = now;
    return fires;
  }

  // MARK: Tempo

  /** Holds the current onset strength on the grid up to `now`. */
  private feedGrid(now: number): void {
    const period = 1 / SoundMusicInference.gridRate;
    const n = SoundMusicInference.gridCount;
    let steps = 0;
    while (this.gridTime + period <= now && steps < n) {
      this.gridTime += period;
      this.gridHead = (this.gridHead + 1) % n;
      this.grid[this.gridHead] = this.strength;
      this.gridFilled = Math.min(this.gridFilled + 1, n);
      steps += 1;
    }
    if (steps === n) this.gridTime = now;
  }

  private estimateTempo(): void {
    const cells = this.grid;
    const linear = this.window;
    const n = SoundMusicInference.gridCount;
    let mean = 0;
    for (let j = 0; j < n; j++) {
      const value = cells[(this.gridHead + 1 + j) % n];
      linear[j] = value;
      mean = f(mean + value);
    }
    mean = f(mean / n);
    let r0 = 0;
    for (let j = 0; j < n; j++) {
      linear[j] = f(linear[j] - mean);
      r0 = f(r0 + f(linear[j] * linear[j]));
    }
    if (!(r0 > 1e-6)) return;
    const fresh = this.correlation;
    const r = this.averaged;
    this.estimates += 1;
    const blend = Math.max(f(1 / this.estimates), f(0.2));
    const { minLag, maxLag, subdivisionLag } = SoundMusicInference;
    for (let lag = subdivisionLag; lag <= maxLag; lag++) {
      let sum = 0;
      for (let j = lag; j < n; j++) sum = f(sum + f(linear[j] * linear[j - lag]));
      fresh[lag] = f(sum / r0);
      r[lag] = f(r[lag] + f(f(fresh[lag] - r[lag]) * blend));
    }
    let bestLag = 0;
    let bestScore = -Infinity;
    for (let lag = minLag; lag <= maxLag; lag++) {
      const s = this.score(lag, r);
      if (s > bestScore) {
        bestScore = s;
        bestLag = lag;
      }
    }
    if (!(bestLag > 0 && r[bestLag] > f(0.08))) return;
    // Parabolic interpolation around the peak for a sub-cell period.
    let lag = bestLag;
    if (bestLag > minLag && bestLag < maxLag) {
      const left = r[bestLag - 1];
      const right = r[bestLag + 1];
      const denominator = f(f(left - f(2 * r[bestLag])) + right);
      if (Math.abs(denominator) > 1e-6) lag += f(f(f(0.5) * f(left - right)) / denominator);
    }
    const measured = (SoundMusicInference.gridRate * 60) / lag;
    if (this.locked && Math.abs(measured - this.bpm) / this.bpm < 0.04) {
      this.bpm += (measured - this.bpm) * 0.3;
      this.agreements = 0;
      return;
    }
    if (this.candidateBPM > 0 && Math.abs(measured - this.candidateBPM) / this.candidateBPM < 0.04) {
      this.agreements += 1;
      this.candidateBPM = (this.candidateBPM + measured) / 2;
    } else {
      this.candidateBPM = measured;
      this.agreements = 1;
    }
    if (this.agreements < (this.locked ? SoundMusicInference.agreementsToSwitch : SoundMusicInference.agreementsToLock)) return;
    if (this.locked) {
      // Leave a locked tempo only for one that clearly outscores it.
      const currentLag = Math.min(Math.max(roundAway((SoundMusicInference.gridRate * 60) / this.bpm), minLag), maxLag);
      if (!(bestScore > f(this.score(currentLag, r) * f(1.4)))) return;
    }
    this.bpm = this.candidateBPM;
    this.candidateBPM = 0;
    this.agreements = 0;
    if (!this.locked) {
      // The clock ran at the default tempo until now: keep its count and snap the phase to the nearest beat, which
      // the kicks then pull into place.
      this.locked = true;
      this.lockTime = this.lastTime;
      this.stepPosition = roundAway(this.stepPosition / 4) * 4;
      this.lastStep = Math.trunc(this.stepPosition);
    }
  }

  /** How much `lag` looks like the beat: its correlation plus its double- and quadruple-time subdivisions, under a gentle prior. */
  private score(lag: number, r: Float32Array): number {
    const { subdivisionLag } = SoundMusicInference;
    const lagBPM = (SoundMusicInference.gridRate * 60) / lag;
    const octaves = Math.log2(lagBPM / 130);
    const prior = f(Math.exp(-0.5 * (octaves / 0.75) * (octaves / 0.75)));
    const half = Math.trunc(lag / 2) >= subdivisionLag ? Math.max(0, r[Math.trunc(lag / 2)]) : 0;
    const quarter = Math.trunc(lag / 4) >= subdivisionLag ? Math.max(0, r[Math.trunc(lag / 4)]) : 0;
    return f(f(f(r[lag] + f(f(0.5) * half)) + f(f(0.25) * quarter)) * prior);
  }

  /** A kick pulls the beat phase toward itself when it lands near a beat. */
  private pullBeat(): void {
    const beat = this.stepPosition / 4;
    let error = beat - roundAway(beat);
    if (error > 0.5) error -= 1;
    if (!(Math.abs(error) < 0.3)) return;
    this.stepPosition -= error * 4 * 0.35;
  }

  /** Runs the clock from the first sound heard: at the default tempo until a lock, then at the measured one. */
  private advanceClock(dt: number, resting: boolean): void {
    if (!this.heard || resting) return;
    this.stepPosition += dt / (60 / this.bpm / 4);
    this.lastStep = Math.max(this.lastStep, Math.floor(this.stepPosition));
  }

  // MARK: Energy and section

  private updateEnergy(frame: SoundFrame, dt: number, silent: boolean, resting: boolean): void {
    if (resting) {
      this.energy = 0;
      this._level = 0;
      this.energySlow = f(this.energySlow + f(f(this.energy - this.energySlow) * Math.min(1, f(dt / 2))));
      return;
    }
    let fromLoudness = 0;
    if (!silent) {
      const rms = f(frame.rmsDB);
      if (!this.heard) {
        this.heard = true;
        this.heardSince = this.lastTime;
        this.loud = rms;
        this.ceiling = rms;
        this.floorDB = rms;
      }
      this.loud = f(this.loud + f(f(rms - this.loud) * Math.min(1, f(dt * (rms > this.loud ? 20 : 1)))));
      // The ceiling holds the loudest recent passage and falls slowly; the floor rises toward the quietest and drops
      // at once.
      this.ceiling = Math.max(this.loud, f(this.ceiling - f(dt * 0.3)));
      this.floorDB = Math.min(this.loud, f(this.floorDB + dt));
      const span = Math.max(f(this.ceiling - this.floorDB), 10);
      const relative = Math.min(Math.max(f(f(this.loud - f(this.ceiling - span)) / span), 0), 1);
      // Half relative to the song's own range, half absolute.
      const absolute = Math.min(Math.max(f(f(this.loud + 32) / 22), 0), 1);
      fromLoudness = f(f(f(0.35) * relative) + f(f(0.65) * absolute));
    }
    const fromDensity = Math.min(f(this.density / 5), 1);
    const target = silent ? 0 : f(f(f(0.65) * fromLoudness) + f(f(0.35) * fromDensity));
    this.energy = f(this.energy + f(f(target - this.energy) * Math.min(1, f(dt * 3))));
    this.energySlow = f(this.energySlow + f(f(this.energy - this.energySlow) * Math.min(1, f(dt / 2))));
    this.energyPeak = Math.max(this.energy, f(this.energyPeak - f(dt * 0.02)));
    this._level = f(this._level + f(f(fromLoudness - this._level) * Math.min(1, f(dt * 3))));
    this._levelPeak = Math.max(this._level, f(this._levelPeak - f(dt * 0.02)));
    this._levelSlow = f(this._levelSlow + f(f(this._level - this._levelSlow) * Math.min(1, f(dt / 2))));
  }

  private updateSection(now: number, resting: boolean): void {
    if (resting) {
      if (this.section !== "intro") {
        this.section = "intro";
        this.sectionSince = now;
      }
      this.highSince = -Infinity;
      this.midSince = -Infinity;
      this.lowSince = -Infinity;
      return;
    }
    // Loudness against the most the song has reached puts each moment in one of three tiers: a drop is held near the
    // peak, a build sits under it and a breakdown well below.
    const level = this._level;
    const levelPeak = this._levelPeak;
    const high = level >= Math.max(f(0.55), f(levelPeak * f(0.85)));
    const low = level < Math.max(f(0.25), f(levelPeak * f(0.55)));
    const mid = !high && !low;
    if (!high) this.highSince = -Infinity;
    else if (this.highSince === -Infinity) this.highSince = now;
    if (!mid) this.midSince = -Infinity;
    else if (this.midSince === -Infinity) this.midSince = now;
    if (!low) this.lowSince = -Infinity;
    else if (this.lowSince === -Infinity) this.lowSince = now;
    const highFor = high ? now - this.highSince : 0;
    const midFor = mid ? now - this.midSince : 0;
    const lowFor = low ? now - this.lowSince : 0;
    const section = this.section;
    const inDrop = section === "drop" || section === "drop2";
    const dwell = now - this.sectionSince;
    // A drop's loudness settles over its first bars; only a passage above that settled peak is a new drop.
    if (inDrop && dwell < 2) this.dropEntryPeak = Math.max(this.dropEntryPeak, level);
    let next: SongSection = section;
    // The first drop must rise out of what came before it; a song that opens in its drop is called one after 4 s.
    const risen = now - this.heardSince >= 2 && level >= f(this._levelSlow * f(1.15));
    const nextDrop: SongSection = this.dropsEntered % 2 === 0 ? "drop" : "drop2";
    if (!inDrop && highFor >= 0.4 && dwell >= 1 && (this.dropsEntered > 0 || risen || highFor >= 4)) {
      next = nextDrop;
    } else if (inDrop && level >= f(this.dropEntryPeak * f(1.12)) && highFor >= 0.4 && dwell >= 2) {
      next = nextDrop; // louder than the drop we are in: a new one
    } else if (inDrop && lowFor >= 1 && dwell >= 2) {
      next = "breakdown";
    } else if (inDrop && midFor >= 0.8 && dwell >= 2) {
      next = "build";
    } else if (section === "build" && lowFor >= 1.5 && dwell >= 2) {
      next = "breakdown";
    } else if (section === "intro" && highFor >= 1 && dwell >= 1) {
      next = "build"; // loud from the start but not yet risen: a build
    } else if ((section === "intro" || section === "breakdown") && midFor >= 1 && level > f(0.3) && dwell >= 1.5) {
      next = "build";
    }
    if (next === section) return;
    if (next === "drop" || next === "drop2") {
      this.dropsEntered += 1;
      this.dropEntryPeak = levelPeak;
      this.counts[Instrument.impact] += 1;
    }
    this.section = next;
    this.sectionSince = now;
  }
}
