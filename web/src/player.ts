import type { SampleSource } from "./audio.js";
import type { MotionPreference } from "./motion.js";
import type { SoundPaletteProvider } from "./palette.js";
import { VISUALIZERS, type VisualizerId } from "./shaders/index.js";
import { SoundVisualizer, type VisualizerStatus } from "./visualizer.js";

export interface SoundPlayerOptions {
  /** A CORS-enabled stream or file URL, an element you already have, or any `SampleSource`. */
  src: string | HTMLMediaElement | SampleSource;
  visual?: VisualizerId;
  renderer?: "auto" | "webgl2" | "canvas2d";
  motion?: MotionPreference;
  palettes?: SoundPaletteProvider;
  /** What the canvas is, for screen readers. */
  label?: string;
  /** The start control's text (default "Tap to start"). */
  startLabel?: string;
}

export interface SoundPlayer {
  readonly visualizer: SoundVisualizer;
  readonly root: HTMLElement;
  /** Plays another source (a URL, an element or a `SampleSource`) in place of the current one. Call it from a gesture. */
  play(src: string | HTMLMediaElement | SampleSource): Promise<void>;
  destroy(): Promise<void>;
}

const STATUS_TEXT: Record<VisualizerStatus, string> = {
  idle: "Ready. Tap to start.",
  loading: "Loading…",
  playing: "Playing",
  paused: "Paused",
  still: "Playing (reduced motion: still picture)",
  silent: "Playing, but no sound reaches the visualizer",
  error: "Could not play",
};

const STYLE_ID = "narduk-sound-web-style";
const STYLE = `
.nsw-player { position: relative; display: grid; grid-template-rows: 1fr auto; gap: 8px; min-height: 240px;
  color: #e8ecf4; font: 15px/1.4 system-ui, -apple-system, sans-serif; }
.nsw-stage { position: relative; min-height: 0; border-radius: 12px; overflow: hidden; background: #02040a; }
.nsw-stage canvas { display: block; width: 100%; height: 100%; }
.nsw-start { position: absolute; inset: 0; display: grid; place-items: center; width: 100%; border: 0; padding: 16px;
  background: rgba(2, 4, 10, 0.72); color: #fff; font: inherit; font-size: 1.15rem; cursor: pointer; }
.nsw-start span { padding: 14px 26px; border-radius: 999px; border: 2px solid #8fdcff; background: #0b1a2c; }
.nsw-start:focus-visible span, .nsw-controls button:focus-visible, .nsw-controls select:focus-visible {
  outline: 3px solid #ffd166; outline-offset: 2px; }
.nsw-start[hidden] { display: none; }
.nsw-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.nsw-controls button, .nsw-controls select { min-height: 44px; min-width: 44px; padding: 0 16px; border-radius: 10px;
  border: 1px solid #5b6b85; background: #111a2a; color: #e8ecf4; font: inherit; }
.nsw-controls button[disabled] { opacity: 0.55; }
.nsw-status { flex: 1 1 12rem; color: #c4cede; }
`;

/**
 * A ready-made player: a canvas with a tap-to-start control (iOS Safari only starts audio from a user gesture), a
 * pause button, a visual picker and a polite live status line. Keyboard operable, 44 px targets, and it follows
 * `prefers-reduced-motion`. Mounts into `container` and returns the visualizer for further control.
 */
export function mountSoundPlayer(container: HTMLElement, options: SoundPlayerOptions): SoundPlayer {
  if (!document.getElementById(STYLE_ID)) {
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = STYLE;
    document.head.append(style);
  }
  const root = el("div", "nsw-player");
  const stage = el("div", "nsw-stage");
  const canvas = document.createElement("canvas");
  canvas.setAttribute("role", "img");
  canvas.setAttribute("aria-label", options.label ?? "Music visualizer");
  const start = el("button", "nsw-start") as HTMLButtonElement;
  start.type = "button";
  const startText = document.createElement("span");
  startText.textContent = options.startLabel ?? "Tap to start";
  start.append(startText);
  stage.append(canvas, start);

  const controls = el("div", "nsw-controls");
  const pause = el("button") as HTMLButtonElement;
  pause.type = "button";
  pause.textContent = "Pause";
  pause.disabled = true;
  pause.setAttribute("aria-pressed", "false");
  const picker = document.createElement("select");
  picker.setAttribute("aria-label", "Visualizer");
  for (const port of VISUALIZERS) picker.append(new Option(port.title, port.id));
  picker.value = options.visual ?? "spectrum";
  const status = el("span", "nsw-status");
  status.setAttribute("role", "status");
  status.setAttribute("aria-live", "polite");
  status.textContent = STATUS_TEXT.idle;
  controls.append(pause, picker, status);
  root.append(stage, controls);
  container.append(root);

  const visualizer = new SoundVisualizer(canvas, {
    visual: picker.value as VisualizerId,
    renderer: options.renderer,
    motion: options.motion,
    palettes: options.palettes,
    onStatus: (next, detail) => {
      status.textContent = detail ? `${STATUS_TEXT[next]}. ${detail}` : STATUS_TEXT[next];
      const paused = next === "paused";
      pause.textContent = paused ? "Play" : "Pause";
      pause.setAttribute("aria-pressed", String(paused));
      pause.disabled = next === "idle" || next === "error";
      if (next === "error") start.hidden = false;
    },
  });

  let current = options.src;
  const play = (src: SoundPlayerOptions["src"]) => {
    // Everything that starts audio runs synchronously inside the caller's click: iOS Safari's rule.
    current = src;
    start.hidden = true;
    return visualizer.start(src).catch((error: unknown) => {
      start.hidden = false;
      startText.textContent = "Tap to try again";
      start.focus();
      throw error;
    });
  };
  start.addEventListener("click", () => {
    play(current).catch(() => {});
    pause.focus();
  });
  pause.addEventListener("click", () => void visualizer.togglePause());
  picker.addEventListener("change", () => visualizer.setVisual(picker.value as VisualizerId));

  return {
    visualizer,
    root,
    play,
    async destroy() {
      await visualizer.destroy();
      root.remove();
    },
  };
}

function el(tag: string, className?: string): HTMLElement {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}
