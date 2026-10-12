import { SoundFrameLayout, emptyFrame, type SoundFrame } from "./frame.js";

/**
 * The analysis half of the contract, ported line for line from NardukSoundAnalysis so a web visualizer sees the same
 * numbers a Swift one does for the same samples: `Loudness`, `SpectrumAnalyzer` (2048-point Hann FFT folded into 64
 * log-spaced bands, 20 Hz - 16 kHz, -72 dB floor, attack 0.65 / release 0.12, the chroma fold) and `SoundAnalyzer`.
 *
 * The Web Audio `AnalyserNode` is used only for its time-domain buffer (`getFloatTimeDomainData`): its own
 * frequency data uses a Blackman window, its own smoothing and a different dB scale, so it would not match.
 * Every buffer is allocated in the constructor; `analyze` allocates nothing but the frame it returns into.
 */
export const Loudness = {
  silenceDB: SoundFrameLayout.silenceDB,

  /** 20 log10 of a linear amplitude; anything at or below 1e-6 reads as silence. */
  decibels(amplitude: number): number {
    return amplitude > 1e-6 ? 20 * Math.log10(amplitude) : SoundFrameLayout.silenceDB;
  },

  /** Peak and RMS over the last `window` samples (all of them when shorter or omitted). */
  measure(samples: ArrayLike<number>, window?: number): { peakDB: number; rmsDB: number } {
    const count = Math.min(Math.max(window ?? samples.length, 0), samples.length);
    if (count <= 0) return { peakDB: SoundFrameLayout.silenceDB, rmsDB: SoundFrameLayout.silenceDB };
    let peak = 0;
    let sum = 0;
    for (let i = samples.length - count; i < samples.length; i++) {
      const x = samples[i];
      peak = Math.max(peak, Math.abs(x));
      sum += x * x;
    }
    return { peakDB: Loudness.decibels(peak), rmsDB: Loudness.decibels(Math.sqrt(sum / count)) };
  },
};

/** In-place iterative radix-2 FFT over preallocated buffers (the Swift `PortableFFT`). */
export class PortableFFT {
  readonly size: number;
  private readonly re: Float64Array;
  private readonly im: Float64Array;
  private readonly cosTable: Float64Array;
  private readonly sinTable: Float64Array;
  private readonly bitReverse: Uint32Array;

  constructor(size: number) {
    if (size < 2 || (size & (size - 1)) !== 0) throw new Error("PortableFFT needs a power-of-two size");
    this.size = size;
    this.re = new Float64Array(size);
    this.im = new Float64Array(size);
    this.cosTable = new Float64Array(size / 2);
    this.sinTable = new Float64Array(size / 2);
    this.bitReverse = new Uint32Array(size);
    for (let k = 0; k < size / 2; k++) {
      const angle = (-2 * Math.PI * k) / size;
      this.cosTable[k] = Math.cos(angle);
      this.sinTable[k] = Math.sin(angle);
    }
    let bits = 0;
    while (1 << bits < size) bits++;
    for (let i = 0; i < size; i++) {
      let reversed = 0;
      for (let b = 0; b < bits; b++) if (i & (1 << b)) reversed |= 1 << (bits - 1 - b);
      this.bitReverse[i] = reversed;
    }
  }

  /** |X_k| for k in 0 ..< size / 2 of a real input of `size` samples. */
  magnitudes(input: Float32Array, output: Float32Array): void {
    const { size, re, im, cosTable, sinTable, bitReverse } = this;
    for (let i = 0; i < size; i++) {
      re[bitReverse[i]] = input[i];
      im[bitReverse[i]] = 0;
    }
    for (let length = 2; length <= size; length *= 2) {
      const halfLength = length / 2;
      const stride = size / length;
      for (let start = 0; start < size; start += length) {
        for (let k = 0; k < halfLength; k++) {
          const wr = cosTable[k * stride];
          const wi = sinTable[k * stride];
          const a = start + k;
          const b = a + halfLength;
          const tr = re[b] * wr - im[b] * wi;
          const ti = re[b] * wi + im[b] * wr;
          re[b] = re[a] - tr;
          im[b] = im[a] - ti;
          re[a] += tr;
          im[a] += ti;
        }
      }
    }
    for (let k = 0; k < size / 2; k++) output[k] = Math.sqrt(re[k] * re[k] + im[k] * im[k]);
  }
}

/** 2048-point Hann-windowed FFT folded into 64 log-spaced bands, dB-normalized to 0 ... 1 and smoothed. */
export class SpectrumAnalyzer {
  static readonly fftSize = 2048;
  static readonly bandCount = SoundFrameLayout.spectrumCount;
  static readonly lowFrequency = 20;
  static readonly highFrequency = 16_000;
  /** The dB range mapped onto 0 ... 1. */
  static readonly floorDB = -72;
  static readonly chromaLowFrequency = 80;
  static readonly chromaHighFrequency = 4_000;

  readonly sampleRate: number;
  readonly bands = new Float32Array(SpectrumAnalyzer.bandCount);
  readonly chroma = new Float32Array(SoundFrameLayout.chromaCount);
  attack = 0.65;
  release = 0.12;

  private readonly fft = new PortableFFT(SpectrumAnalyzer.fftSize);
  private readonly window = new Float32Array(SpectrumAnalyzer.fftSize);
  private readonly windowed = new Float32Array(SpectrumAnalyzer.fftSize);
  private readonly magnitudes = new Float32Array(SpectrumAnalyzer.fftSize / 2);
  private readonly bandLow = new Int32Array(SpectrumAnalyzer.bandCount);
  private readonly bandHigh = new Int32Array(SpectrumAnalyzer.bandCount);
  private readonly bandCenter = new Float32Array(SpectrumAnalyzer.bandCount);
  private readonly chromaFirstBin: number;
  private readonly chromaLastBin: number;
  private readonly chromaSums = new Float32Array(SoundFrameLayout.chromaCount);

  constructor(sampleRate: number) {
    this.sampleRate = sampleRate;
    const n = SpectrumAnalyzer.fftSize;
    const half = n / 2;
    // vDSP_HANN_NORM: 0.5 * (1 - cos(2 pi i / N)).
    for (let i = 0; i < n; i++) this.window[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / n));
    const binHz = sampleRate / n;
    const ratio = SpectrumAnalyzer.highFrequency / SpectrumAnalyzer.lowFrequency;
    for (let i = 0; i < SpectrumAnalyzer.bandCount; i++) {
      const lo = SpectrumAnalyzer.lowFrequency * Math.pow(ratio, i / SpectrumAnalyzer.bandCount);
      const hi = SpectrumAnalyzer.lowFrequency * Math.pow(ratio, (i + 1) / SpectrumAnalyzer.bandCount);
      this.bandLow[i] = Math.min(Math.max(Math.ceil(lo / binHz), 1), half - 1);
      this.bandHigh[i] = Math.min(Math.max(Math.floor(hi / binHz), 1), half - 1);
      this.bandCenter[i] = Math.sqrt(lo * hi) / binHz;
    }
    this.chromaFirstBin = Math.max(Math.ceil(SpectrumAnalyzer.chromaLowFrequency / binHz), 1);
    this.chromaLastBin = Math.min(Math.floor(SpectrumAnalyzer.chromaHighFrequency / binHz), half - 2);
  }

  /** The center frequency of `band` in Hz. */
  centerFrequency(band: number): number {
    return (this.bandCenter[band] * this.sampleRate) / SpectrumAnalyzer.fftSize;
  }

  /**
   * Analyzes the most recent `fftSize` samples (oldest first; shorter input is zero-padded at the front) and
   * returns the smoothed bands (the analyzer's own array: copy it to keep it).
   */
  process(samples: ArrayLike<number>): Float32Array {
    const n = SpectrumAnalyzer.fftSize;
    const half = n / 2;
    const count = Math.min(samples.length, n);
    const pad = n - count;
    const { windowed, window, magnitudes } = this;
    for (let i = 0; i < pad; i++) windowed[i] = 0;
    const start = samples.length - count;
    for (let i = 0; i < count; i++) windowed[pad + i] = samples[start + i] * window[pad + i];
    this.fft.magnitudes(windowed, magnitudes);
    // Match vDSP's zrip scaling (2x the DFT), then amplitude = |X| * 2 / N.
    const scale = 4 / n;
    for (let k = 0; k < half; k++) magnitudes[k] *= scale;

    const floor = SpectrumAnalyzer.floorDB;
    for (let b = 0; b < SpectrumAnalyzer.bandCount; b++) {
      let amplitude = 0;
      if (this.bandLow[b] <= this.bandHigh[b]) {
        for (let k = this.bandLow[b]; k <= this.bandHigh[b]; k++) if (magnitudes[k] > amplitude) amplitude = magnitudes[k];
      } else {
        const x = this.bandCenter[b];
        const k = Math.min(Math.max(Math.trunc(x), 1), half - 2);
        const frac = x - k;
        amplitude = magnitudes[k] + (magnitudes[k + 1] - magnitudes[k]) * frac;
      }
      const level = Math.min(Math.max((Loudness.decibels(amplitude) - floor) / -floor, 0), 1);
      const previous = this.bands[b];
      this.bands[b] = previous + (level - previous) * (level > previous ? this.attack : this.release);
    }
    this.foldChroma();
    return this.bands;
  }

  /** Folds the spectrum's peaks into 12 pitch classes at their true (parabola-refined) frequency. */
  private foldChroma(): void {
    const { magnitudes, chromaSums, chroma } = this;
    chromaSums.fill(0);
    const binHz = this.sampleRate / SpectrumAnalyzer.fftSize;
    for (let k = this.chromaFirstBin; k <= this.chromaLastBin; k++) {
      const m = magnitudes[k];
      if (!(m > 1e-6 && m > magnitudes[k - 1] && m >= magnitudes[k + 1])) continue;
      const alpha = Math.log(Math.max(magnitudes[k - 1], 1e-9));
      const beta = Math.log(m);
      const gamma = Math.log(Math.max(magnitudes[k + 1], 1e-9));
      const curvature = alpha - 2 * beta + gamma;
      const offset = curvature < -1e-6 ? Math.min(Math.max((0.5 * (alpha - gamma)) / curvature, -0.5), 0.5) : 0;
      const frequency = (k + offset) * binHz;
      const midi = 69 + 12 * Math.log2(frequency / 440);
      const pitchClass = ((swiftRound(midi) % 12) + 12) % 12;
      if (m > chromaSums[pitchClass]) chromaSums[pitchClass] = m;
    }
    let strongest = 0;
    for (let c = 0; c < 12; c++) if (chromaSums[c] > strongest) strongest = chromaSums[c];
    const floor = SpectrumAnalyzer.floorDB;
    const gate = Math.min(Math.max((Loudness.decibels(strongest) - floor) / -floor, 0), 1);
    for (let c = 0; c < 12; c++) {
      const level = strongest > 0 ? (chromaSums[c] / strongest) * gate : 0;
      const previous = chroma[c];
      chroma[c] = previous + (level - previous) * (level > previous ? this.attack : this.release);
    }
  }

  /** Forgets the smoothing history: the next `process` starts from silence. */
  reset(): void {
    this.bands.fill(0);
    this.chroma.fill(0);
  }
}

/** Swift's `rounded()`: to nearest, ties away from zero (JavaScript's Math.round rounds ties up). */
export function swiftRound(x: number): number {
  return x < 0 ? -Math.round(-x) : Math.round(x);
}

/** Turns the most recent samples of any mono audio into a `SoundFrame` (the Swift `SoundAnalyzer`). */
export class SoundAnalyzer {
  static readonly windowSize = SpectrumAnalyzer.fftSize;

  readonly sampleRate: number;
  /** The trailing samples peak and RMS are measured over (one display frame by default). */
  readonly loudnessWindow: number;
  private _sequence = 0;
  private readonly spectrumAnalyzer: SpectrumAnalyzer;

  constructor(sampleRate: number, loudnessSeconds = 1 / 60) {
    this.sampleRate = sampleRate;
    this.loudnessWindow = Math.min(Math.max(Math.trunc(sampleRate * loudnessSeconds), 1), SoundAnalyzer.windowSize);
    this.spectrumAnalyzer = new SpectrumAnalyzer(sampleRate);
  }

  get sequence(): number {
    return this._sequence;
  }

  /**
   * Analyzes `samples` (oldest first; the last `windowSize` are used) into `into` (a fresh frame when omitted) and
   * returns it. Reusing one frame keeps the render loop allocation-free.
   */
  analyze(samples: ArrayLike<number>, time: number, into: SoundFrame = emptyFrame()): SoundFrame {
    this._sequence += 1;
    const spectrum = this.spectrumAnalyzer.process(samples);
    const { peakDB, rmsDB } = Loudness.measure(samples, this.loudnessWindow);
    const waveform = into.waveform;
    waveform.fill(0);
    const copied = Math.min(samples.length, waveform.length);
    for (let i = 0; i < copied; i++) waveform[waveform.length - copied + i] = samples[samples.length - copied + i];
    into.sequence = this._sequence;
    into.time = time;
    into.spectrum.set(spectrum);
    into.chroma.set(this.spectrumAnalyzer.chroma);
    into.peakDB = peakDB;
    into.rmsDB = rmsDB;
    return into;
  }

  /** Clears the spectrum smoothing and the sequence, as if newly created. */
  reset(): void {
    this._sequence = 0;
    this.spectrumAnalyzer.reset();
  }
}
