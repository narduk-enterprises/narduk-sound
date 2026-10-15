/**
 * What any sound is doing, ~60 Hz: the web twin of `SoundFrame` (Sources/NardukSoundAnalysis/SoundFrame.swift,
 * docs/sound-contract.md section 2). Every visualizer must work from this alone.
 *
 * Poll frames on the visualizer's own clock (`requestAnimationFrame`); `sequence` says whether a poll returned a new
 * frame without comparing the arrays.
 */
export interface SoundFrame {
  /** Increases by one for every new analysis a source produces. 0 is the empty frame before any analysis. */
  sequence: number;
  /** Seconds on the source's clock. Used for staleness and replay, never for animation. */
  time: number;
  /** Log-spaced magnitude bands, 0 ... 1 (64 bands, 20 Hz - 16 kHz). */
  spectrum: Float32Array;
  /** How strongly each pitch class sounds, 0 ... 1 (index 0 = C ... 11 = B). All zero in silence. */
  chroma: Float32Array;
  /** The latest waveform, mono, -1 ... 1 (512 samples, oldest first). */
  waveform: Float32Array;
  /** Peak and RMS over the most recent analysis window, in dBFS (silence is -120). */
  peakDB: number;
  rmsDB: number;
}

/** The named constants of `SoundFrame`; a visualizer never writes the numbers. */
export const SoundFrameLayout = {
  spectrumCount: 64,
  waveformCount: 512,
  chromaCount: 12,
  silenceDB: -120,
} as const;

/** The empty frame (sequence 0): silence everywhere. */
export function emptyFrame(): SoundFrame {
  return {
    sequence: 0,
    time: 0,
    spectrum: new Float32Array(SoundFrameLayout.spectrumCount),
    chroma: new Float32Array(SoundFrameLayout.chromaCount),
    waveform: new Float32Array(SoundFrameLayout.waveformCount),
    peakDB: SoundFrameLayout.silenceDB,
    rmsDB: SoundFrameLayout.silenceDB,
  };
}
