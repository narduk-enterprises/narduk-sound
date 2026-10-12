import { SyntheticSource, mountSoundPlayer, type VisualizerId } from "../src/index.js";

// https://listen.kzfr.org/stream sends Access-Control-Allow-Origin: *, so Web Audio may read its samples.
const STREAM = "https://listen.kzfr.org/stream";

const params = new URLSearchParams(location.search);
const synthetic = params.has("synthetic");
const visual = (params.get("visual") as VisualizerId | null) ?? "halo";
const renderer = (params.get("renderer") as "auto" | "webgl2" | "canvas2d" | null) ?? "auto";

const container = document.getElementById("player")!;
const player = mountSoundPlayer(container, {
  src: synthetic ? new SyntheticSource() : (params.get("src") ?? STREAM),
  visual,
  renderer,
  label: "Visualizer for the KZFR live stream",
});
const viz = player.visualizer;

document.getElementById("renderer-note")!.textContent =
  viz.renderer.kind === "webgl2" ? "Drawn with WebGL2." : "WebGL2 is unavailable here, so this is the Canvas2D fallback.";

const still = document.getElementById("still") as HTMLInputElement;
still.checked = viz.isStatic;
still.addEventListener("change", () => viz.setMotion(still.checked ? "static" : "auto"));

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

// For the browser smoke test.
(globalThis as unknown as { soundDemo: unknown }).soundDemo = { viz, player };
