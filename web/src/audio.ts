import { SoundAnalyzer } from "./analysis.js";

/** What the visualizer listens to: an `<audio>`/`<video>` element, a stream URL, or a `MediaStream` (mic, WebRTC). */
export type SoundSourceInput = HTMLMediaElement | MediaStream | string;

type AudioContextConstructor = typeof AudioContext;

/** The page's AudioContext class, including Safari's prefixed one on older iOS. */
export function audioContextClass(): AudioContextConstructor | undefined {
  const w = globalThis as unknown as { AudioContext?: AudioContextConstructor; webkitAudioContext?: AudioContextConstructor };
  return w.AudioContext ?? w.webkitAudioContext;
}

/**
 * An `<audio>` element for a stream URL, set up for analysis: `crossOrigin = "anonymous"` before the URL (without it
 * a cross-origin stream plays but reaches Web Audio as silence), inline playback on iOS, and no preload until the user
 * starts it.
 */
export function createStreamElement(url: string): HTMLAudioElement {
  const audio = new Audio();
  audio.crossOrigin = "anonymous";
  audio.preload = "none";
  audio.setAttribute("playsinline", "");
  audio.src = url;
  return audio;
}

// createMediaElementSource may be called once per element for its whole life; remember each element's node.
const elementSources = new WeakMap<HTMLMediaElement, MediaElementAudioSourceNode>();

/** Anything that hands the visualizer the latest mono samples: an `AudioTap`, or a synthetic source in a test. */
export interface SampleSource {
  readonly sampleRate: number;
  /** The latest `SoundAnalyzer.windowSize` samples, oldest first (the source's own buffer: read, don't keep). */
  read(): Float32Array;
  start(): Promise<void>;
  pause(): Promise<void>;
  resume(): Promise<void>;
  readonly isPaused: boolean;
  /** The element playing the sound, if any (the visualizer listens for "playing" and "pause" on it). */
  readonly element: HTMLMediaElement | null;
  close(): Promise<void>;
}

/**
 * A Web Audio tap: the source routed through an `AnalyserNode` (and on to the speakers for an element), read each
 * frame with `getFloatTimeDomainData` into a fixed buffer for `SoundAnalyzer`, the port of the Swift analysis.
 * Construct it inside a user gesture (a tap or a click): iOS Safari only starts audio from one.
 */
export class AudioTap implements SampleSource {
  readonly context: AudioContext;
  readonly analyser: AnalyserNode;
  readonly element: HTMLMediaElement | null;
  /** The latest `SoundAnalyzer.windowSize` samples, oldest first. */
  readonly samples = new Float32Array(SoundAnalyzer.windowSize);
  private readonly source: AudioNode;

  constructor(input: SoundSourceInput, context?: AudioContext) {
    const Context = audioContextClass();
    if (!context && !Context) throw new Error("Web Audio is not available in this browser");
    this.context = context ?? new Context!({ latencyHint: "playback" });
    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = SoundAnalyzer.windowSize;
    this.analyser.smoothingTimeConstant = 0;
    if (typeof input === "string") input = createStreamElement(input);
    if (input instanceof MediaStream) {
      this.element = null;
      this.source = this.context.createMediaStreamSource(input);
      // A live input is analyzed, never played back (it would feed back through the speakers).
      this.source.connect(this.analyser);
    } else {
      this.element = input;
      let node = elementSources.get(input);
      if (!node || node.context !== this.context) {
        node = this.context.createMediaElementSource(input);
        elementSources.set(input, node);
      }
      this.source = node;
      this.source.connect(this.analyser);
      this.analyser.connect(this.context.destination);
    }
  }

  get sampleRate(): number {
    return this.context.sampleRate;
  }

  /** Resumes the context and plays the element. Call from the same user gesture that built the tap. */
  async start(): Promise<void> {
    // Safari 17+: play through the ringer switch, like a music app.
    const session = (navigator as unknown as { audioSession?: { type: string } }).audioSession;
    if (session) {
      try {
        session.type = "playback";
      } catch {
        /* not settable here; harmless */
      }
    }
    const resumed = this.context.state === "running" ? Promise.resolve() : this.context.resume();
    const played = this.element ? this.element.play() : Promise.resolve();
    await Promise.all([resumed, played]);
  }

  /** Pauses playback (an element) or the whole context (a live stream). */
  async pause(): Promise<void> {
    if (this.element) this.element.pause();
    else await this.context.suspend();
  }

  async resume(): Promise<void> {
    await this.start();
  }

  get isPaused(): boolean {
    return this.element ? this.element.paused : this.context.state !== "running";
  }

  /** Copies the latest samples into `samples`. */
  read(): Float32Array {
    this.analyser.getFloatTimeDomainData(this.samples);
    return this.samples;
  }

  disconnect(): void {
    this.source.disconnect();
    this.analyser.disconnect();
  }

  /** Closes the context (the element can be reused with a new tap only in the same context, a Web Audio rule). */
  async close(): Promise<void> {
    this.disconnect();
    if (this.element) this.element.pause();
    await this.context.close();
  }
}
