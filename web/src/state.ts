import { SoundFrameLayout, type SoundFrame } from "./frame.js";
import { DefaultSoundPaletteProvider, saturated, type SoundPalette, type SoundPaletteProvider } from "./palette.js";

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
 * (Sources/NardukSoundVisuals/SoundVisualState.swift) for a source with no `MusicContext`, which is every web source
 * (an `<audio>` element or a stream). It keeps the Swift rules exactly: the clock at the default tempo, the smoothed
 * spectrum with peak caps, the waveform history ring, the meters, the low-band kick onset, energy and "wild" from the
 * level, the palette from the smoothed spectral centroid (saturated by wild), and travel. Hit counters, sections,
 * particles and the musical (pitch / key) state need a `MusicContext` or `SoundMusicInference` and are not ported;
 * their envelopes stay 0, as they do in Swift for a source without music.
 *
 * `update` is idempotent per display frame (a second call within 2 ms returns). Every buffer is allocated in the
 * constructor; a frame allocates only the three palette colors. All time comes in as `now`, never from a clock, so
 * the tests drive the same state.
 */
export class SoundVisualState {
  static readonly bandCount = SoundFrameLayout.spectrumCount;
  static readonly sampleCount = SoundFrameLayout.waveformCount;
  static readonly historyDepth = 10;

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
  driveLevel = 0;
  wild = 0;
  calm = false;
  /** The palette after the drive-driven saturation. */
  palette: SoundPalette;
  private basePalette: SoundPalette;
  private centroid = 0;

  private lastUpdate = 0;
  private started = false;
  private lastSequence = 0;
  private lowBandPrevious = 0;

  constructor(
    configuration: SoundVisualConfiguration = wirewatcherConfiguration,
    palettes: SoundPaletteProvider = new DefaultSoundPaletteProvider(),
  ) {
    this.configuration = configuration;
    this.palettes = palettes;
    const initial = palettes.palette({ section: "intro" });
    this.palette = initial;
    this.basePalette = initial;
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

  /** Advances the state to `now` (seconds on any monotonic clock) from the latest `frame`. */
  update(frame: SoundFrame, now: number, options: SoundVisualOptions = {}): void {
    const elapsed = now - this.lastUpdate;
    if (this.started && elapsed < 0.002) return;
    // Swift keeps dt as a Float; rounding it the same way keeps hold timers on the same frame.
    const dt = Math.fround(this.started ? Math.min(Math.max(elapsed, 0), 0.1) : 1 / 60);
    if (this.started && elapsed > 0) this.fps += (1 / elapsed - this.fps) * 0.05;
    this.started = true;
    this.lastUpdate = now;
    this.time = now;
    this.calm = options.calm ?? false;

    const previousStepPosition = this.stepPosition;
    // No music: the beat clock runs on wall time at the last known tempo; `beatPulse` stays 0.
    this.isRunning = false;
    this.stepPosition += dt / Math.max(this.secondsPerStep, 0.01);
    const deltaBeats = Math.max(0, this.stepPosition - previousStepPosition) / 4;

    this.decayEnvelopes(dt);
    const isNewFrame = frame.sequence !== this.lastSequence || this.lastSequence === 0;
    if (isNewFrame) {
      this.lastSequence = frame.sequence;
      this.ingest(frame);
    }
    this.smoothSpectrum(frame.spectrum, dt);
    this.updateMeters(frame, dt);
    this.updateDrive(options.drive, dt);
    // No section: the palette follows the signal's spectral centroid instead.
    this.basePalette = this.palettes.palette({ scalar: this.centroid });
    this.updateMotion(dt, deltaBeats);
  }

  private ingest(frame: SoundFrame): void {
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
    this.wobbleCutoff = 0;
    this.wobblePhase = 0;

    // Onset fallback on the low bands, for sources without hit counters.
    let low = 0;
    const n = Math.min(6, frame.spectrum.length);
    for (let i = 0; i < n; i++) low += frame.spectrum[i];
    if (n > 0) low /= n;
    if (low - this.lowBandPrevious > 0.28 && this.kick < 0.3) this.kick = 0.8;
    this.lowBandPrevious = low;
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

  private updateMotion(dt: number, deltaBeats: number): void {
    // Energy: the signal's level (a conductor's energy when there is music, which the web never has).
    this.energy += (this.level - this.energy) * Math.min(1, dt * (this.calm ? 1 : 3));
    this.dropAmount += (0 - this.dropAmount) * Math.min(1, dt * (this.calm ? 1 : 4));
    this.palette = saturated(this.basePalette, 0.45 + 0.62 * this.wild);

    // Tunnel travel at the intro's speed; a kick pushes forward.
    const speed = 0.35;
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
