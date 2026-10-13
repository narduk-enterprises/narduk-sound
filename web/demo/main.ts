import {
  SyntheticSource,
  VISUALIZERS,
  decodeSoundTimeline,
  mountSoundPlayer,
  type SoundTimeline,
  type VisualizerId,
} from "../src/index.js";

// https://listen.kzfr.org/stream sends Access-Control-Allow-Origin: *, so Web Audio may read its samples.
const STREAM = "https://listen.kzfr.org/stream";

const params = new URLSearchParams(location.search);
const synthetic = params.has("synthetic");
const asked = params.get("visual");
const visual: VisualizerId = VISUALIZERS.some((v) => v.id === asked) ? (asked as VisualizerId) : "halo";
const renderer = (params.get("renderer") as "auto" | "webgl2" | "canvas2d" | null) ?? "auto";

const container = document.getElementById("player")!;
const player = mountSoundPlayer(container, {
  src: synthetic ? new SyntheticSource() : (params.get("src") ?? STREAM),
  visual,
  renderer,
  label: "Visualizer for the KZFR live stream",
  // Keep ?visual= in step, so a link opens the look that was showing.
  onVisualChange: (id) => {
    const url = new URL(location.href);
    url.searchParams.set("visual", id);
    history.replaceState(null, "", url);
  },
});
const viz = player.visualizer;

document.getElementById("renderer-note")!.textContent =
  viz.renderer.kind === "webgl2" ? "Drawn with WebGL2." : "WebGL2 is unavailable here, so this is the Canvas2D fallback.";

const still = document.getElementById("still") as HTMLInputElement;
still.checked = viz.isStatic;
still.addEventListener("change", () => viz.setMotion(still.checked ? "static" : "auto"));

// Auto-cycle: the next look every 30 s while it plays (never in reduced motion, where only a still is shown).
const cycle = document.getElementById("cycle") as HTMLInputElement;
let cycleTimer: ReturnType<typeof setInterval> | undefined;
const syncCycle = () => {
  clearInterval(cycleTimer);
  if (cycle.checked)
    cycleTimer = setInterval(() => {
      if (viz.status === "playing") player.stepVisual(1);
    }, 30_000);
};
cycle.checked = params.has("cycle");
cycle.addEventListener("change", syncCycle);
syncCycle();

// Page-wide keys when nothing else has focus: the arrows step the look, F is full screen, space pauses.
document.addEventListener("keydown", (event) => {
  if (event.target !== document.body || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.key === "ArrowRight" || event.key === "ArrowLeft") player.stepVisual(event.key === "ArrowRight" ? 1 : -1);
  else if (event.key === "f" || event.key === "F") player.toggleFullscreen();
  else if (event.key === " " && viz.status !== "idle") void viz.togglePause();
  else return;
  event.preventDefault();
});

const budget = document.getElementById("budget")!;
setInterval(() => {
  const d = viz.governor.decision;
  budget.textContent = `Budget: ${d.fps} fps at ${d.pixelRatio.toFixed(2)}x${viz.governor.lowEnd ? " (low-end device)" : ""}`;
}, 1000);

// Sources: the live stream, a local file (an object URL, so it is same-origin) or any CORS-enabled URL. Each starts
// inside its own click or change event, which iOS Safari requires.
let objectUrl: string | null = null;
const playFrom = (src: string) => {
  if (objectUrl && src !== objectUrl) {
    URL.revokeObjectURL(objectUrl);
    objectUrl = null;
  }
  player.play(src).catch(() => {});
};
document.getElementById("live")!.addEventListener("click", () => playFrom(STREAM));
const file = document.getElementById("file") as HTMLInputElement;
file.addEventListener("change", () => {
  const chosen = file.files?.[0];
  if (!chosen) return;
  const url = URL.createObjectURL(chosen);
  playFrom(url);
  objectUrl = url;
});
const urlInput = document.getElementById("url") as HTMLInputElement;
document.getElementById("url-form")!.addEventListener("submit", (event) => {
  event.preventDefault();
  const value = urlInput.value.trim();
  if (/^https?:\/\//i.test(value)) {
    playFrom(value);
    return;
  }
  urlInput.setCustomValidity("Enter an http(s) URL");
  urlInput.reportValidity();
  urlInput.setCustomValidity("");
});

// Timeline mode (`?timeline=<url>`, `?timeline=fixture` or `?ambient`): the visualizer draws from a recorded
// SoundTimeline (NSTL v1) and a synthetic playhead, with no audio and no tap to start. The playhead runs from 0, then
// past the end into the ambient drift for three seconds, then starts over; a timeline URL must send
// Access-Control-Allow-Origin.
const timelineParam = params.get("timeline");
const demo = { hold: false };
if (timelineParam !== null || params.has("ambient")) {
  container.querySelector<HTMLElement>(".nsw-start")!.hidden = true;
  const note = document.getElementById("timeline-note")!;
  let clock = 0;
  let last = performance.now() / 1000;
  let timeline: SoundTimeline | null = null;
  const playhead = () => {
    // A paused visualizer stops polling; the gap is not playing time.
    const now = performance.now() / 1000;
    // `hold` is for the browser smoke test: an unknown playhead (null) holds, then fades to the ambient drift.
    const dt = demo.hold ? 0 : Math.min(now - last, 0.1);
    clock += dt;
    last = now;
    if (timeline && clock > timeline.header.duration + 3) clock = 0;
    return demo.hold ? null : clock;
  };
  const load = async (): Promise<SoundTimeline> => {
    if (timelineParam === "fixture") {
      const { default: fixture } = await import("../fixtures/sound-timeline.json");
      return decodeSoundTimeline(Uint8Array.from(atob(fixture.nstl), (c) => c.charCodeAt(0)));
    }
    const response = await fetch(timelineParam!);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return decodeSoundTimeline(await response.arrayBuffer());
  };
  if (timelineParam === null) {
    viz.setAmbient(true);
    note.textContent = "Ambient drift: no sound, no timeline.";
  } else {
    // Until it loads (or when it fails) the ambient drift shows.
    viz.setAmbient(true);
    load().then(
      (loaded) => {
        timeline = loaded;
        viz.setTimeline(loaded, playhead);
        note.textContent = `Timeline ${loaded.header.trackID}: ${loaded.header.duration.toFixed(1)} s, ${loaded.header.tempoBPM?.toFixed(0) ?? "no"} BPM, drawn from the recording with no audio.`;
      },
      (error: unknown) => {
        note.textContent = `Could not load the timeline: ${error instanceof Error ? error.message : String(error)}. Showing the ambient drift.`;
      },
    );
  }
}

// For the browser smoke test.
(globalThis as unknown as { soundDemo: unknown }).soundDemo = { viz, player, demo };
