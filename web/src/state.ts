import { SoundFrameLayout, type SoundFrame } from "./frame.js";
import { HIT_LANE_COUNT, Instrument, type MusicContext } from "./inference.js";
import {
  DefaultSoundPaletteProvider,
  mixed,
  saturated,
  type SongSection,
  type SoundPalette,
  type SoundPaletteProvider,
} from "./palette.js";

/**
 * The constants of `SoundVisualConfiguration` (Sources/NardukSoundVisuals/SoundVisualConfiguration.swift) the web
 * state reads. Defaults are Wirewatcher's, the state's source of truth.
 */
export interface SoundVisualConfiguration {
  spectrumAttack: number;
  spectrumRelease: number;
  calmSpectrumAttack: number;
  calmSpectrumRelease: number;
  capHold: number;
  capFall: number;
  levelFloorDB: number;
  meterFloorDB: number;
  meterPeakFall: number;
  meterRMSFall: number;
  meterHoldTime: number;
  meterHoldFall: number;
}

/** Whether lane `lane` of `hits` moved since `last` (counters wrap, so the difference is an unsigned 32-bit one). */
function struck(hits: Uint32Array, last: Uint32Array, lane: number): boolean {
  return ((hits[lane] - last[lane]) >>> 0) > 0;
}

/** `SongSection.historyCode`: stable small codes for the section history ring (never renumbered). */
const SECTION_CODES: Readonly<Record<SongSection, number>> = {
  intro: 0,
  build: 1,
  drop: 2,
  breakdown: 3,
  drop2: 4,
};

export const wirewatcherConfiguration: Readonly<SoundVisualConfiguration> = Object.freeze({
  spectrumAttack: 34,
  spectrumRelease: 8,
  calmSpectrumAttack: 10,
  calmSpectrumRelease: 3.5,
  capHold: 0.4,
  capFall: 0.55,
  levelFloorDB: -48,
  meterFloorDB: -60,
  meterPeakFall: 1.2,
  meterRMSFall: 0.9,
  meterHoldTime: 0.8,
  meterHoldFall: 0.5,
});

/** What the stage should do beyond the signal itself (`SoundVisualOptions`). */
export interface SoundVisualOptions {
  /** Calm (Reduce Motion): gates flash, shake, chroma and glitch; slower smoothing. */
  calm?: boolean;
  /** A generic 0 ... 1 external drive; omitted means "as loud as the signal". */
  drive?: number;
}

/**
 * The per-render-frame state every visualizer draws from: the web port of `SoundVisualState`
 * (Sources/NardukSoundVisuals/SoundVisualState.swift). It keeps the Swift rules exactly: the beat clock, the smoothed
 * spectrum with peak caps, the waveform history ring, the meters, the low-band kick onset, energy and "wild", the
 * palette (from the smoothed spectral centroid, or the section's with a blend), and travel.
 *
 * Without a `MusicContext` (the `music` argument of `update` omitted) the clock runs on wall time at the last known
 * tempo and only `kick` (the low-band onset) fires, as in Swift. With one (from `SoundMusicInference`, which hears a
 * stream the way the Swift side hears a recording) the clock follows its step, its hit counters fire the `kick`,
 * `snare`, `hat`, `glitch`, `laser` and `impact` envelopes with their flash, shake and chroma triggers, and its
 * sections switch the palette and the tunnel speed. Not ported: the particle pool and its pads (no web renderer draws
 * them) and the musical state (pitch classes, key, piano roll).
 *
 * `update` is idempotent per display frame (a second call within 2 ms returns). Every buffer is allocated in the
 * constructor; a frame allocates only the three palette colors. All time comes in as `now`, never from a clock, so
 * the tests drive the same state.
 */
export class SoundVisualState {
  static readonly bandCount = SoundFrameLayout.spectrumCount;
  static readonly sampleCount = SoundFrameLayout.waveformCount;
  static readonly historyDepth = 10;
  static readonly energyHistoryCount = 128;

  readonly configuration: SoundVisualConfiguration;
  private readonly palettes: SoundPaletteProvider;

  readonly spectrum = new Float32Array(SoundVisualState.bandCount);
  readonly peaks = new Float32Array(SoundVisualState.bandCount);
  private readonly peakAge = new Float32Array(SoundVisualState.bandCount);
  readonly waveform = new Float32Array(SoundVisualState.sampleCount);
  /** Ring of recent waveforms, historyDepth x sampleCount; newest at historyHead. */
  readonly history = new Float32Array(SoundVisualState.sampleCount * SoundVisualState.historyDepth);
  historyHead = 0;
  historyCount = 0;

  // Meters, 0 ... 1.
  peak = 0;
  rms = 0;
  peakHold = 0;
  private holdTimer = 0;
  /** True when there is nothing to show: RMS below -100 dB and no band above 0.002. */
  isSilent = true;

  // Clock.
  time = 0;
  stepPosition = 0;
  secondsPerStep = 60 / 140 / 4;
  stepsPerBar = 16;
  fps = 60;
  isRunning = false;

  // Envelopes 0 ... 1. Without a MusicContext only `kick` (the low-band onset) ever fires.
  kick = 0;
  snare = 0;
  hat = 0;
  glitch = 0;
  laser = 0;
  impact = 0;
  flash = 0;
  shake = 0;
  shakeOffset: [number, number] = [0, 0];
  chroma = 0;

  wobbleCutoff = 0;
  wobblePhase = 0;
  energy = 0;
  level = 0;
  dropAmount = 0;
  travel = 0;
  section: SongSection = "intro";
  phraseProgress = 0;
  buildThreshold = 0;
  dropThreshold = 0;
  dropQueued = false;
  /** Conductor energy at each step, newest at `energyHead - 1`. */
  readonly energyHistory = new Float32Array(SoundVisualState.energyHistoryCount);
  /** `SongSection` history codes (intro 0, build 1, drop 2, breakdown 3, drop2 4) parallel to `energyHistory`. */
  readonly sectionHistory = new Uint8Array(SoundVisualState.energyHistoryCount);
  energyHead = 0;
  driveLevel = 0;
  wild = 0;
  calm = false;
  /** The palette after the drive-driven saturation. */
  palette: SoundPalette;
  private basePalette: SoundPalette;
  private paletteFrom: SoundPalette;
  private paletteTo: SoundPalette;
  private paletteT = 1;
  private paletteDuration = 1;
  private centroid = 0;

  private lastUpdate = 0;
  private started = false;
  private lastSequence = 0;
  private lowBandPrevious = 0;
  private lastStep = -Infinity;
  private lastStepTime = 0;
  private lastFlashTime = -10;
  private lastChromaTime = -10;
  private lastEnergyStep = -Infinity;
  private readonly lastHits = new Uint32Array(HIT_LANE_COUNT);
  private haveHits = false;

  constructor(
    configuration: SoundVisualConfiguration = wirewatcherConfiguration,
    palettes: SoundPaletteProvider = new DefaultSoundPaletteProvider(),
  ) {
    this.configuration = configuration;
    this.palettes = palettes;
    const initial = palettes.palette({ section: "intro" });
    this.palette = initial;
    this.basePalette = initial;
    this.paletteFrom = initial;
    this.paletteTo = initial;
  }

  get beats(): number {
    return this.stepPosition / 4;
  }
  get beatPhase(): number {
    return this.beats - Math.floor(this.beats);
  }
  get barPhase(): number {
    const bars = this.stepPosition / Math.max(this.stepsPerBar, 1);
    return bars - Math.floor(bars);
  }
  /** 1 on the beat, decaying through it; 0 without a running music clock. */
  get beatPulse(): number {
    return this.isRunning ? Math.exp(-this.beatPhase * 5) : 0;
  }

  /**
   * Advances the state to `now` (seconds on any monotonic clock) from the latest `frame`, and `music` when the source
   * is music (`SoundMusicInference.update`'s result; omit it for a source that is not).
   */
  update(frame: SoundFrame, now: number, options: SoundVisualOptions = {}, music?: MusicContext): void {
    const elapsed = now - this.lastUpdate;
    if (this.started && elapsed < 0.002) return;
    // Swift keeps dt as a Float; rounding it the same way keeps hold timers on the same frame.
    const dt = Math.fround(this.started ? Math.min(Math.max(elapsed, 0), 0.1) : 1 / 60);
    if (this.started && elapsed > 0) this.fps += (1 / elapsed - this.fps) * 0.05;
    // First frame, or back after the view was hidden: don't replay a backlog of hits.
    const stale = !this.started || elapsed > 0.5;
    this.started = true;
    this.lastUpdate = now;
    this.time = now;
    this.calm = options.calm ?? false;

    const previousStepPosition = this.stepPosition;
    this.advanceClock(music, now, dt);
    const deltaBeats = Math.max(0, this.stepPosition - previousStepPosition) / 4;

    this.decayEnvelopes(dt);
    const isNewFrame = frame.sequence !== this.lastSequence || this.lastSequence === 0;
    if (isNewFrame) {
      this.lastSequence = frame.sequence;
      this.ingest(frame, music, now, stale);
    }
    if (music) this.energyStep(music);
    this.smoothSpectrum(frame.spectrum, dt);
    this.updateMeters(frame, dt);
    this.updateDrive(options.drive, dt);
    this.updateSection(music, now);
    this.updateMotion(dt, deltaBeats, music);
  }

  /**
   * Forgets the hit counters and the step the last `MusicContext` carried. Call it when the inference is reset (a new
   * source): its counters start again at 0, which against the old ones would read as a wrapped burst of hits.
   */
  resetMusic(): void {
    this.haveHits = false;
    this.lastStep = -Infinity;
    this.lastEnergyStep = -Infinity;
  }

  private advanceClock(music: MusicContext | undefined, now: number, dt: number): void {
    if (!music) {
      // No music: the beat clock runs on wall time at the last known tempo; `beatPulse` stays 0.
      this.isRunning = false;
      this.stepPosition += dt / Math.max(this.secondsPerStep, 0.01);
      return;
    }
    this.isRunning = music.isRunning;
    this.secondsPerStep = music.secondsPerStep;
    this.stepsPerBar = Math.max(music.stepsPerBar, 1);
    this.phraseProgress = music.phraseProgress;
    this.buildThreshold = music.buildThreshold;
    this.dropThreshold = music.dropThreshold;
    this.dropQueued = music.dropQueued;
    if (music.step !== this.lastStep) {
      if (this.lastStep === -Infinity || music.step < this.lastStep || music.step > this.lastStep + 8) {
        this.stepPosition = music.step; // first frame, a reset, or a seek
      }
      this.lastStep = music.step;
      this.lastStepTime = now;
    }
    const fraction = this.isRunning ? Math.min((now - this.lastStepTime) / Math.max(this.secondsPerStep, 0.01), 0.97) : 0;
    this.stepPosition = Math.max(this.stepPosition, music.step + fraction);
  }

  private energyStep(music: MusicContext): void {
    if (music.step === this.lastEnergyStep) return;
    this.lastEnergyStep = music.step;
    this.energyHistory[this.energyHead] = music.energy;
    this.sectionHistory[this.energyHead] = SECTION_CODES[music.section];
    this.energyHead = (this.energyHead + 1) % SoundVisualState.energyHistoryCount;
  }

  private ingest(frame: SoundFrame, music: MusicContext | undefined, now: number, stale: boolean): void {
    const count = Math.min(frame.waveform.length, SoundVisualState.sampleCount);
    for (let i = 0; i < count; i++) this.waveform[i] = frame.waveform[i];
    this.historyHead = (this.historyHead + 1) % SoundVisualState.historyDepth;
    const next = this.historyHead * SoundVisualState.sampleCount;
    for (let i = 0; i < count; i++) this.history[next + i] = this.waveform[i];
    this.historyCount = Math.min(this.historyCount + 1, SoundVisualState.historyDepth);

    const floor = this.configuration.levelFloorDB;
    this.level = Math.max(0, Math.min(1, (frame.rmsDB - floor) / -floor));
    let best = 0;
    for (let i = 0; i < frame.spectrum.length; i++) if (frame.spectrum[i] > best) best = frame.spectrum[i];
    this.isSilent = frame.rmsDB < -100 && best <= 0.002;
    let sawKick = false;
    if (music) {
      this.wobbleCutoff = music.wobbleCutoff;
      this.wobblePhase = music.wobblePhase;
      if (!this.haveHits || stale) {
        // Nothing to diff against yet, or back after a long gap: adopt the counters without firing.
        this.lastHits.set(music.hitCounts);
        this.haveHits = true;
      } else {
        sawKick = this.fire(music.hitCounts, now);
      }
    } else {
      this.wobbleCutoff = 0;
      this.wobblePhase = 0;
    }

    // Onset fallback on the low bands, for sources whose hit counters are sparse or absent.
    let low = 0;
    const n = Math.min(6, frame.spectrum.length);
    for (let i = 0; i < n; i++) low += frame.spectrum[i];
    if (n > 0) low /= n;
    if (!sawKick && low - this.lowBandPrevious > 0.28 && this.kick < 0.3) this.kick = 0.8;
    this.lowBandPrevious = low;
  }

  /**
   * Reacts to the hits since the last frame (`hits` against the counters seen then) and remembers `hits`; returns
   * whether a kick fired. Counters wrap, so each difference is taken as an unsigned 32-bit subtraction.
   */
  private fire(hits: Uint32Array, now: number): boolean {
    const last = this.lastHits;
    let sawKick = false;
    if (struck(hits, last, Instrument.kick)) {
      this.kick = 1;
      sawKick = true;
      // A busy stage shakes the camera on every kick.
      if (!this.calm && this.wild > 0.6) this.shake = Math.max(this.shake, (this.wild - 0.6) * 0.9);
    }
    if (struck(hits, last, Instrument.snare)) {
      this.snare = 1;
      if (!this.calm && now - this.lastChromaTime > 0.34) {
        this.chroma = 1;
        this.lastChromaTime = now;
      }
    }
    const open = struck(hits, last, Instrument.openHat);
    if (open || struck(hits, last, Instrument.hat)) this.hat = Math.max(this.hat, open ? 1 : 0.6);
    if (struck(hits, last, Instrument.glitch) || struck(hits, last, Instrument.scratch)) this.glitch = 1;
    if (struck(hits, last, Instrument.laser)) this.laser = 1;
    if (struck(hits, last, Instrument.impact)) {
      this.impact = 1;
      if (!this.calm) this.shake = Math.max(this.shake, 0.7);
    }
    last.set(hits);
    return sawKick;
  }

  private smoothSpectrum(target: Float32Array, dt: number): void {
    const c = this.configuration;
    const attack = this.calm ? c.calmSpectrumAttack : c.spectrumAttack;
    const release = this.calm ? c.calmSpectrumRelease : c.spectrumRelease;
    const count = Math.min(target.length, SoundVisualState.bandCount);
    let weighted = 0;
    let total = 0;
    for (let i = 0; i < count; i++) {
      const goal = Math.min(Math.max(target[i], 0), 1);
      let value = this.spectrum[i];
      value += (goal - value) * Math.min(1, dt * (goal > value ? attack : release));
      this.spectrum[i] = value;
      if (value >= this.peaks[i]) {
        this.peaks[i] = value;
        this.peakAge[i] = 0;
      } else {
        this.peakAge[i] += dt;
        if (this.peakAge[i] > c.capHold) this.peaks[i] = Math.max(value, this.peaks[i] - dt * c.capFall);
      }
      weighted += i * goal;
      total += goal;
    }
    if (total > 0.001) {
      const measured = weighted / total / Math.max(SoundVisualState.bandCount - 1, 1);
      this.centroid += (measured - this.centroid) * Math.min(1, dt * 2);
    }
  }

  private updateMeters(frame: SoundFrame, dt: number): void {
    const c = this.configuration;
    const norm = (db: number) => Math.min(1, Math.max(0, (db - c.meterFloorDB) / -c.meterFloorDB));
    const targetPeak = norm(frame.peakDB);
    const targetRMS = norm(frame.rmsDB);
    this.peak = targetPeak > this.peak ? targetPeak : Math.max(targetPeak, this.peak - dt * c.meterPeakFall);
    this.rms = targetRMS > this.rms ? targetRMS : Math.max(targetRMS, this.rms - dt * c.meterRMSFall);
    if (this.peak >= this.peakHold) {
      this.peakHold = this.peak;
      this.holdTimer = c.meterHoldTime;
    } else if (this.holdTimer > 0) {
      this.holdTimer -= dt;
    } else {
      this.peakHold = Math.max(this.peak, this.peakHold - dt * c.meterHoldFall);
    }
  }

  private updateDrive(drive: number | undefined, dt: number): void {
    let blended: number;
    if (drive !== undefined) {
      const target = Math.min(Math.max(drive, 0), 1);
      this.driveLevel += (target - this.driveLevel) * Math.min(1, dt * (target > this.driveLevel ? 4 : 1.2));
      blended = 0.65 * this.driveLevel + 0.35 * this.energy;
    } else {
      this.driveLevel = 0;
      blended = this.energy;
    }
    this.wild = this.calm ? Math.min(blended * 0.35, 0.3) : Math.min(1, blended);
  }

  private decayEnvelopes(dt: number): void {
    this.kick *= Math.exp(-dt / 0.16);
    this.snare *= Math.exp(-dt / 0.2);
    this.hat *= Math.exp(-dt / 0.07);
    this.glitch *= Math.exp(-dt / 0.14);
    this.laser *= Math.exp(-dt / 0.3);
    this.impact *= Math.exp(-dt / 0.6);
    this.flash *= Math.exp(-dt / 0.16);
    this.shake *= Math.exp(-dt / 0.32);
    this.chroma *= Math.exp(-dt / 0.12);
    if (this.calm) {
      this.flash = 0;
      this.shake = 0;
      this.chroma = 0;
      this.glitch = 0;
    }
  }

  private updateSection(music: MusicContext | undefined, now: number): void {
    if (!music) {
      // No section: the palette follows the signal's spectral centroid instead.
      this.section = "intro";
      this.basePalette = this.palettes.palette({ scalar: this.centroid });
      this.paletteT = 1;
      return;
    }
    const next = music.section;
    if (next === this.section) return;
    this.paletteFrom = this.basePalette;
    this.paletteTo = this.palettes.palette({ section: next });
    this.paletteT = 0;
    const isDrop = next === "drop" || next === "drop2";
    this.paletteDuration = isDrop && !this.calm ? 0.12 : 1.4;
    if (isDrop && !this.calm && now - this.lastFlashTime > 0.4) {
      this.flash = 0.9;
      this.shake = 1;
      this.lastFlashTime = now;
    }
    this.section = next;
  }

  private updateMotion(dt: number, deltaBeats: number, music: MusicContext | undefined): void {
    // Energy: the conductor's when there is one, else the signal's level.
    const target = music ? music.energy : this.level;
    this.energy += (target - this.energy) * Math.min(1, dt * (this.calm ? 1 : 3));
    const isDrop = music !== undefined && (this.section === "drop" || this.section === "drop2");
    this.dropAmount += ((isDrop ? 1 : 0) - this.dropAmount) * Math.min(1, dt * (this.calm ? 1 : 4));

    if (this.paletteT < 1) {
      this.paletteT = Math.min(1, this.paletteT + dt / this.paletteDuration);
      const s = this.paletteT * this.paletteT * (3 - 2 * this.paletteT);
      this.basePalette = mixed(this.paletteFrom, this.paletteTo, s);
    }
    this.palette = saturated(this.basePalette, 0.45 + 0.62 * this.wild);

    // Tunnel travel: one ring per beat at speed 1, a kick pushes forward.
    let speed: number;
    switch (this.section) {
      case "intro":
        speed = 0.35;
        break;
      case "build":
        speed = 0.5 + 0.7 * this.phraseProgress;
        break;
      case "drop":
        speed = 1.0;
        break;
      case "breakdown":
        speed = 0.22;
        break;
      case "drop2":
        speed = 1.25;
        break;
    }
    const calmScale = this.calm ? 0.4 : 1;
    this.travel += deltaBeats * speed * calmScale * (0.55 + 0.9 * this.wild) + (this.calm ? 0 : this.kick * dt * 0.9);
    if (!this.isRunning) this.travel += dt * 0.04;

    if (this.shake > 0.001) {
      const t = this.time % 3600;
      const k = this.shake * 0.018 * (0.5 + this.wild);
      this.shakeOffset[0] = (Math.sin(t * 71) + 0.5 * Math.sin(t * 113)) * k;
      this.shakeOffset[1] = (Math.cos(t * 53) + 0.5 * Math.cos(t * 97)) * k;
    } else {
      this.shakeOffset[0] = 0;
      this.shakeOffset[1] = 0;
    }
  }
}
