import { SoundAnalyzer } from "./analysis.js";
import { AudioTap, type SampleSource, type SoundSourceInput } from "./audio.js";
import { FrameGovernor } from "./budget.js";
import { Canvas2DRenderer } from "./canvas2d.js";
import { AmbientFeed, TimelineFeed, type InputFeed } from "./feed.js";
import { emptyFrame } from "./frame.js";
import { LiveDrive } from "./live.js";
import { SoundMusicInference } from "./inference.js";
import { isStatic, watchReducedMotion, type MotionPreference } from "./motion.js";
import type { SoundPaletteProvider } from "./palette.js";
import type { SoundRenderer } from "./renderer.js";
import { LumaWatchdog } from "./safety.js";
import type { VisualizerId } from "./shaders/index.js";
import { SoundVisualState } from "./state.js";
import { StreamSource, UnsupportedStreamError } from "./stream.js";
import type { SoundTimeline } from "./timeline.js";
import { ShaderInputs } from "./uniforms.js";
import { WebGLRenderer } from "./webgl.js";

export type VisualizerStatus =
  /** Built, waiting for `start` (show a tap-to-start control). */
  | "idle"
  /** Starting or buffering. */
  | "loading"
  | "playing"
  | "paused"
  /** Reduced motion: the sound plays and a still picture of it is shown. */
  | "still"
  /** Playing, but every sample is zero: usually a cross-origin stream without CORS headers. */
  | "silent"
  | "error";

/** What the visualizer draws from: a playing sound, a recorded timeline, the quiet ambient drift, or nothing yet. */
export type VisualizerDriver = "audio" | "timeline" | "ambient" | null;

export interface SoundVisualizerOptions {
  visual?: VisualizerId;
  /** "auto" tries WebGL2 and falls back to Canvas2D. */
  renderer?: "auto" | "webgl2" | "canvas2d";
  /** "auto" follows `prefers-reduced-motion`. */
  motion?: MotionPreference;
  palettes?: SoundPaletteProvider;
  /** Caps the backing store's pixels per CSS pixel (default 2, or 1.5 on a low-end device). */
  maxDevicePixelRatio?: number;
  onStatus?: (status: VisualizerStatus, detail?: string) => void;
}

/** Seconds of all-zero samples while playing before the status turns "silent". */
const SILENT_AFTER = 4;
/** Seconds after playback starts before the reduced-motion still is taken. */
const STILL_AFTER = 1.5;

/**
 * Plays a sound source through a ported visualizer on a canvas: the analysis, the shared state, the renderer, the
 * flash rules and the frame budget in one object.
 *
 * - `start(source)` must run inside a user gesture (iOS Safari starts audio only from one). Build a tap-to-start
 *   control around it, or use `mountSoundPlayer`, which does.
 * - `pause()` stops the sound and holds the last frame (WCAG 2.2.2); `resume()` continues.
 * - With `prefers-reduced-motion: reduce` (or `motion: "static"`) nothing animates: one still of the current sound
 *   is drawn, in calm mode, and redrawn only on a visual change or a resize.
 * - Hidden tabs and off-screen canvases draw nothing; the governor holds the frame budget on slow devices.
 */
export class SoundVisualizer {
  readonly state: SoundVisualState;
  readonly governor: FrameGovernor;
  private _canvas: HTMLCanvasElement;
  private _renderer: SoundRenderer;
  private source: SampleSource | null = null;
  /** The timeline and playhead `setTimeline` was given, and whether `setAmbient` is on. */
  private timelineSpec: { timeline: SoundTimeline; playhead: () => number | null } | null = null;
  private ambient = false;
  /** Draws timeline or ambient frames when there is no audio source (null while audio plays or nothing is set). */
  private feed: InputFeed | null = null;
  private analyzer: SoundAnalyzer | null = null;
  /** One per source: hears the hits, tempo and sections in the analyzer's frames (reset when the source changes). */
  private readonly music = new SoundMusicInference();
  private readonly frame = emptyFrame();
  private readonly inputs = new ShaderInputs();
  /** The web-only layer that stretches a compressed stream's drive after the state (see `LiveDrive`). */
  private readonly live = new LiveDrive();
  private readonly watchdog = new LumaWatchdog();
  private visual: VisualizerId;
  private motion: MotionPreference;
  private prefersReduced: boolean;
  private readonly stopMotionWatch: () => void;
  private readonly onStatus?: (status: VisualizerStatus, detail?: string) => void;
  private _status: VisualizerStatus = "idle";
  private raf = 0;
  private lastDraw = -Infinity;
  private pageVisible = true;
  private onScreen = true;
  private silentSince = -1;
  private stillTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly resizeObserver?: ResizeObserver;
  private readonly intersectionObserver?: IntersectionObserver;
  private readonly cleanups: (() => void)[] = [];
  private sourceCleanups: (() => void)[] = [];

  constructor(canvas: HTMLCanvasElement, options: SoundVisualizerOptions = {}) {
    this._canvas = canvas;
    this.visual = options.visual ?? "spectrum";
    this.motion = options.motion ?? "auto";
    this.onStatus = options.onStatus;
    this.state = new SoundVisualState(undefined, options.palettes);
    const nav = navigator as Navigator & { deviceMemory?: number; connection?: { saveData?: boolean } };
    this.governor = new FrameGovernor(
      {
        devicePixelRatio: globalThis.devicePixelRatio ?? 1,
        hardwareConcurrency: nav.hardwareConcurrency,
        deviceMemory: nav.deviceMemory,
        saveData: nav.connection?.saveData,
      },
      { maxDevicePixelRatio: options.maxDevicePixelRatio },
    );
    this._renderer = this.makeRenderer(options.renderer ?? "auto");
    this._renderer.setVisual(this.visual);

    const motion = watchReducedMotion((reduce) => {
      this.prefersReduced = reduce;
      this.applyMotion();
    });
    this.prefersReduced = motion.reduce;
    this.stopMotionWatch = motion.stop;

    const onVisibility = () => {
      this.pageVisible = document.visibilityState !== "hidden";
      this.updateVisibility();
    };
    document.addEventListener("visibilitychange", onVisibility);
    this.cleanups.push(() => document.removeEventListener("visibilitychange", onVisibility));
    if (typeof ResizeObserver === "function") {
      this.resizeObserver = new ResizeObserver(() => this.applySize());
      this.resizeObserver.observe(canvas);
    }
    if (typeof IntersectionObserver === "function") {
      this.intersectionObserver = new IntersectionObserver((entries) => {
        this.onScreen = entries.some((e) => e.isIntersecting);
        this.updateVisibility();
      });
      this.intersectionObserver.observe(canvas);
    }
    this.applySize();
  }

  /** The canvas drawn into (a fresh one replaces the original if WebGL2 failed after taking it). */
  get canvas(): HTMLCanvasElement {
    return this._canvas;
  }
  get renderer(): SoundRenderer {
    return this._renderer;
  }
  get status(): VisualizerStatus {
    return this._status;
  }
  get isStatic(): boolean {
    return isStatic(this.motion, this.prefersReduced);
  }
  get currentVisual(): VisualizerId {
    return this.visual;
  }
  /** What is being drawn from: "audio" (a source was started), "timeline", "ambient", or null. */
  get driver(): VisualizerDriver {
    if (this.source) return "audio";
    if (this.feed instanceof TimelineFeed) return "timeline";
    return this.feed ? "ambient" : null;
  }

  /**
   * Starts `input` (an element, a stream URL, a MediaStream or a ready `SampleSource`). Call it from a user gesture.
   * A second call replaces the source.
   */
  async start(input: SoundSourceInput | SampleSource): Promise<void> {
    await this.stopSource();
    // Sound replaces a timeline (and the ambient drift) as the driver.
    this.timelineSpec = null;
    this.feed = null;
    this.setStatus("loading");
    // An http(s) URL is fetched and decoded (StreamSource): WebKit's media-element path reads a live stream as
    // silence. A blob: URL, an element or a MediaStream goes through the AudioTap.
    const streamed = typeof input === "string" && /^https?:/i.test(input) && StreamSource.isSupported();
    const source = isSampleSource(input) ? input : streamed ? new StreamSource(input) : new AudioTap(input);
    this.source = source;
    this.analyzer = new SoundAnalyzer(source.sampleRate);
    this.music.reset();
    this.state.resetMusic();
    this.live.reset();
    const element = source.element;
    if (element) {
      const onPlaying = () => this.onPlaying();
      const onWaiting = () => this._status === "playing" && this.setStatus("loading");
      const onPause = () => {
        if (this._status !== "paused") this.enterPaused();
      };
      const onError = () => this.setStatus("error", describeMediaError(element));
      element.addEventListener("playing", onPlaying);
      element.addEventListener("waiting", onWaiting);
      element.addEventListener("pause", onPause);
      element.addEventListener("error", onError);
      this.sourceCleanups.push(() => {
        element.removeEventListener("playing", onPlaying);
        element.removeEventListener("waiting", onWaiting);
        element.removeEventListener("pause", onPause);
        element.removeEventListener("error", onError);
      });
    }
    try {
      await source.start();
    } catch (error) {
      // Neither MP3 nor AAC: hand the URL to a media element instead.
      if (error instanceof UnsupportedStreamError && typeof input === "string" && this.source === source) {
        await source.close().catch(() => {});
        this.source = null;
        return this.start(new AudioTap(input));
      }
      this.setStatus("error", error instanceof Error ? error.message : String(error));
      throw error;
    }
    if (!element) this.onPlaying();
  }

  async pause(): Promise<void> {
    if (!this.driven) return;
    this.enterPaused();
    await this.source?.pause();
  }

  async resume(): Promise<void> {
    if (!this.driven) return;
    this.setStatus("loading");
    await this.source?.resume();
    if (!this.source?.element) this.onPlaying();
  }

  async togglePause(): Promise<void> {
    if (this._status === "paused") await this.resume();
    else await this.pause();
  }

  /**
   * Draws from a recorded `SoundTimeline` instead of audio, with no sound and no user gesture. `playhead` is polled every
   * frame: seconds into the track, or `null` while paused or unknown, which holds the last picture (beat clock stopped)
   * and then fades it to the quiet ambient drift (see `TimelineFeed`). A playhead at or past the timeline's duration
   * counts as unknown. The visualizer's state and flash rules run exactly as for live audio.
   *
   * Replaces a playing audio source (stopped here), and a later `start()` replaces the timeline. `setTimeline(null, ...)`
   * returns to the ambient drift when `setAmbient(true)` is on, else the visualizer goes idle. Under reduced motion it
   * draws one still of the current playhead, redrawn when `setTimeline`, `setVisual` or a resize asks.
   */
  setTimeline(timeline: SoundTimeline | null, playhead: () => number | null): void {
    this.timelineSpec = timeline ? { timeline, playhead } : null;
    if (timeline && this.source) void this.stopSource();
    this.applyFeed(true);
  }

  /**
   * With no audio source and no timeline, draws the quiet `AmbientDrift` (a slow breathing near 0.15 energy; no beat, no
   * hits) when `on`. A timeline or a started source takes precedence; the ambient drift is still what a timeline fades
   * to while its playhead is null.
   */
  setAmbient(on: boolean): void {
    if (on === this.ambient) return;
    this.ambient = on;
    this.applyFeed(false);
  }

  setVisual(id: VisualizerId): void {
    this.visual = id;
    this._renderer.setVisual(id);
    if (this.isStatic && this.driven) this.drawStill();
  }

  setMotion(preference: MotionPreference): void {
    this.motion = preference;
    this.applyMotion();
  }

  async destroy(): Promise<void> {
    this.stopLoop();
    clearTimeout(this.stillTimer);
    await this.stopSource();
    this.stopMotionWatch();
    this.resizeObserver?.disconnect();
    this.intersectionObserver?.disconnect();
    for (const cleanup of this.cleanups.splice(0)) cleanup();
    this._renderer.destroy();
  }

  // MARK: Internals

  /** True while something feeds the picture: a started audio source, a timeline or the ambient drift. */
  private get driven(): boolean {
    return this.source !== null || this.feed !== null;
  }

  /**
   * Picks the feed the current settings call for (a timeline, else the ambient drift, else none) and starts drawing it.
   * `fresh` builds a new feed even when the kind is unchanged (a new timeline or playhead). A new feed tells the state
   * to adopt its hit counters without firing, so switching never reads as a burst of hits.
   */
  private applyFeed(fresh: boolean): void {
    if (this.source) return;
    const kind = this.timelineSpec ? "timeline" : this.ambient ? "ambient" : null;
    const current = this.feed === null ? null : this.feed instanceof TimelineFeed ? "timeline" : "ambient";
    if (kind === current && !fresh) return;
    this.feed = this.timelineSpec
      ? new TimelineFeed(this.timelineSpec.timeline, this.timelineSpec.playhead)
      : this.ambient
        ? new AmbientFeed()
        : null;
    this.state.resetMusic();
    this.live.reset();
    if (this.feed) {
      this.silentSince = -1;
      this.onPlaying(0);
    } else {
      this.stopLoop();
      clearTimeout(this.stillTimer);
      this.setStatus("idle");
    }
  }

  private makeRenderer(kind: "auto" | "webgl2" | "canvas2d"): SoundRenderer {
    if (kind === "canvas2d") return new Canvas2DRenderer(this._canvas);
    try {
      const renderer = new WebGLRenderer(this._canvas);
      const onLost = (event: Event) => {
        event.preventDefault();
        this.stopLoop();
      };
      const onRestored = () => {
        this._renderer = new WebGLRenderer(this._canvas);
        this._renderer.setVisual(this.visual);
        this.applySize();
        this.applyMotion();
      };
      this._canvas.addEventListener("webglcontextlost", onLost);
      this._canvas.addEventListener("webglcontextrestored", onRestored);
      this.cleanups.push(() => {
        this._canvas.removeEventListener("webglcontextlost", onLost);
        this._canvas.removeEventListener("webglcontextrestored", onRestored);
      });
      return renderer;
    } catch (error) {
      if (kind === "webgl2") throw error;
      // A canvas that handed out a WebGL context can never give a 2D one: swap in a fresh element.
      if (this._canvas.getContext("2d") === null) {
        const fresh = this._canvas.cloneNode(false) as HTMLCanvasElement;
        this._canvas.replaceWith(fresh);
        this._canvas = fresh;
      }
      return new Canvas2DRenderer(this._canvas);
    }
  }

  private onPlaying(stillDelay = STILL_AFTER): void {
    this.silentSince = -1;
    if (this.isStatic) {
      this.setStatus("still");
      clearTimeout(this.stillTimer);
      this.stillTimer = setTimeout(() => this.drawStill(), stillDelay * 1000);
    } else {
      this.setStatus("playing");
      this.startLoop();
    }
  }

  private enterPaused(): void {
    this.stopLoop();
    clearTimeout(this.stillTimer);
    this.setStatus("paused");
  }

  private applyMotion(): void {
    if (!this.driven || this._status === "paused" || this._status === "idle" || this._status === "error") return;
    if (this.isStatic) {
      this.stopLoop();
      this.setStatus("still");
      this.drawStill();
    } else {
      this.setStatus("playing");
      this.startLoop();
    }
  }

  private applySize(): void {
    const rect = this._canvas.getBoundingClientRect();
    const cssWidth = rect.width || this._canvas.clientWidth || 300;
    const cssHeight = rect.height || this._canvas.clientHeight || 150;
    const { width, height } = this.governor.backingSize(cssWidth, cssHeight);
    this._renderer.resize(width, height);
    // A resize clears the canvas: redraw a held picture once.
    if (this.driven && (this._status === "paused" || this._status === "still")) this.drawHeld();
  }

  private updateVisibility(): void {
    const visible = this.pageVisible && this.onScreen;
    this.governor.setVisible(visible);
    if (!visible) this.stopLoop();
    else if (this._status === "playing" || this._status === "silent" || this._status === "loading") this.startLoop();
  }

  private startLoop(): void {
    if (this.raf || !this.driven || this.isStatic) return;
    if (!(this.pageVisible && this.onScreen)) return;
    this.lastDraw = -Infinity;
    this.raf = requestAnimationFrame(this.tick);
  }

  private stopLoop(): void {
    if (this.raf) cancelAnimationFrame(this.raf);
    this.raf = 0;
  }

  private readonly tick = (ms: number) => {
    this.raf = requestAnimationFrame(this.tick);
    if (!this.governor.shouldDraw(ms, this.lastDraw)) return;
    const interval = this.lastDraw === -Infinity ? 1000 / this.governor.decision.fps : ms - this.lastDraw;
    this.lastDraw = ms;
    const t0 = performance.now();
    this.step(ms / 1000);
    const work = performance.now() - t0;
    if (this.governor.record(ms, work, interval)) {
      // A resize clears the canvas: draw the same frame again at the new size, so no blank frame shows.
      this.applySize();
      this.redraw();
    }
  };

  /** Draws the last frame again at the canvas's new size, without advancing the state or the flash limiter. */
  private redraw(): void {
    this.inputs.uniforms[0] = this._canvas.width;
    this.inputs.uniforms[1] = this._canvas.height;
    this._renderer.draw(this.inputs, this.state, this.watchdog.gain);
  }

  /** One animated frame at `now` seconds. */
  private step(now: number): void {
    if (this.feed) {
      // A timeline or the ambient drift: no analysis, and nothing to watch for silence (a recorded intro can be silent).
      const input = this.feed.input(now);
      this.state.update(input.frame, now, {}, input.music);
    } else if (this.source && this.analyzer) {
      const frame = this.analyzer.analyze(this.source.read(), now, this.frame);
      this.state.update(frame, now, {}, this.music.update(frame));
      this.watchSilence(now);
    } else return;
    const luma = this._renderer.takeLuma();
    const gain = luma === null ? this.watchdog.gain : this.watchdog.observe(luma, now);
    this.inputs.fill(this.state, this._canvas.width, this._canvas.height);
    this.live.apply(this.inputs, this.state, now, this.feed ? this.feed.liveAmount : 1);
    this._renderer.draw(this.inputs, this.state, gain);
  }

  private watchSilence(now: number): void {
    const silent = this.frame.peakDB <= -120;
    if (!silent) {
      this.silentSince = -1;
      if (this._status === "silent" || this._status === "loading") this.setStatus("playing");
      return;
    }
    if (this.silentSince < 0) this.silentSince = now;
    else if (this._status === "playing" && now - this.silentSince > SILENT_AFTER) {
      this.setStatus(
        "silent",
        "The sound is playing but no samples reach the visualizer: the stream may be silent, or a cross-origin source lacks CORS headers (Access-Control-Allow-Origin).",
      );
    }
  }

  /**
   * The reduced-motion still: settles the state on the current sound in calm mode (the smoothing needs a few
   * frames to reach it) and draws once.
   */
  private drawStill(): void {
    if (!this.isStatic) return;
    const base = performance.now() / 1000;
    if (this.feed) {
      for (let i = 0; i < 24; i++) {
        const input = this.feed.input(base + i / 60);
        this.state.update(input.frame, base + i / 60, { calm: true }, input.music);
      }
    } else if (this.source && this.analyzer) {
      for (let i = 0; i < 24; i++) {
        const frame = this.analyzer.analyze(this.source.read(), base + i / 60, this.frame);
        this.state.update(frame, base + i / 60, { calm: true });
      }
    } else return;
    this.drawHeld();
  }

  /** Draws the state as it stands, without advancing it. */
  private drawHeld(): void {
    this.inputs.fill(this.state, this._canvas.width, this._canvas.height);
    this._renderer.draw(this.inputs, this.state, 1);
  }

  private async stopSource(): Promise<void> {
    this.stopLoop();
    const source = this.source;
    this.source = null;
    for (const cleanup of this.sourceCleanups.splice(0)) cleanup();
    this.analyzer = null;
    if (source) await source.close().catch(() => {});
  }

  private setStatus(status: VisualizerStatus, detail?: string): void {
    if (status === this._status && detail === undefined) return;
    this._status = status;
    this.onStatus?.(status, detail);
  }
}

function isSampleSource(input: unknown): input is SampleSource {
  return typeof input === "object" && input !== null && typeof (input as SampleSource).read === "function";
}

function describeMediaError(element: HTMLMediaElement): string {
  const code = element.error?.code;
  if (code === 2) return "A network error stopped the stream.";
  if (code === 3) return "The stream could not be decoded.";
  if (code === 4) return "The stream URL is not supported, unreachable, or blocked by CORS.";
  return "The sound could not be played.";
}
