# @narduk-enterprises/sound-web

The Narduk Sound visualizers in a browser. Plays any `<audio>` element or CORS-enabled stream URL through a Web Audio
`AnalyserNode`, runs the same analysis and visual state as `NardukSoundVisuals` (Swift), and draws the Metal looks
ported to WebGL2, with a Canvas2D fallback. Live demo: <https://visualizers.nard.uk>.

| Visual     | Metal source                                          |
| ---------- | ----------------------------------------------------- |
| `spectrum` | `Intense/SpectrumMetal/SpectrumMetalShader.swift`     |
| `scope`    | `Intense/ScopeMetal/ScopeMetalShader.swift`           |
| `halo`     | `Intense/HaloMetal/HaloMetalShader.swift`             |
| `vortex`   | `Intense/VortexMetal/VortexMetalShader.swift`         |
| `hyperspaceLasers` | `Intense/Hyperspace/HyperspaceShader.swift`   |
| `kaleidoscope` | `Intense/KaleidoscopeMetal/KaleidoscopeMetalShader.swift` |
| `blackHole` | `Intense/Promoted/BlackHoleShader.swift`             |
| `geometricChaos` | `Intense/Promoted/GeometricChaosShader.swift`   |
| `audioTerrain` | `Intense/AudioTerrainMetal/AudioTerrainMetalShader.swift` |

## Use

```ts
import { mountSoundPlayer } from "@narduk-enterprises/sound-web";

const player = mountSoundPlayer(document.getElementById("player")!, {
  src: "https://listen.kzfr.org/stream", // or an HTMLMediaElement, or a SampleSource
  visual: "halo",
  label: "KZFR 90.1 FM",
});
```

The player draws a tap-to-start button, then a pause/play button, a visual picker and a polite live status line. For
your own controls, drive the canvas directly:

```ts
import { SoundVisualizer } from "@narduk-enterprises/sound-web";

const viz = new SoundVisualizer(canvas, { visual: "spectrum", renderer: "auto", motion: "auto", onStatus: console.log });
button.onclick = () => viz.start("https://example.com/stream.mp3"); // call start inside the user's gesture
viz.togglePause();
viz.setVisual("scope");
viz.destroy();
```

Options: `renderer` `"auto" | "webgl2" | "canvas2d"`, `motion` `"auto" | "full" | "static"`, `palettes` (a
`SoundPaletteProvider`), `maxDevicePixelRatio`. Statuses: `idle`, `loading`, `playing`, `paused`, `still`, `silent`,
`error`.

## Browser rules

- **iOS Safari:** audio starts only from a tap, so `start()` must run inside the click handler (the player's start
  button does this). The page asks for the `playback` audio session where the browser supports it, so the ring/silent
  switch does not mute the stream.
- **CORS:** Web Audio reads samples only from a cross-origin stream that sends `Access-Control-Allow-Origin`. The
  element is created with `crossOrigin = "anonymous"`. Without the header the audio plays but the analyser reads
  zeros; after 4 s of silence the status turns `silent` and says so.
- **Flashing:** every flash goes through the same limiter and luma watchdog as the Swift renderer (3 flashes a
  second at most, WCAG 2.1 AA 2.3.1).
- **Reduced motion:** with `prefers-reduced-motion: reduce` (or `motion: "static"`) the visualizer shows one still
  picture of the sound and redraws it only when it changes or the canvas resizes. The audio keeps playing.
- **Frame budget:** 60 fps, 30 on a low-end phone (four cores or fewer, 2 GB or less, or Save-Data), nothing while
  hidden or off screen. When frames run long the backing resolution steps down, then the rate; it recovers after 4 s
  of calm.

## Develop

```sh
npm ci
npm run demo             # http://localhost:5173 plays KZFR; ?synthetic plays a built-in beat; ?visual=scope
npm run check            # types, unit tests (incl. the Swift contract fixture and glslang), build, demo build
npm run test:browser     # headless Chromium: each visual on WebGL2 and Canvas2D, pause, file input, reduced motion
npm run deploy           # builds the demo and deploys visualizers.nard.uk (docs/web-port.md, "The public demo")
```

The shader compile test needs `glslangValidator` on the PATH or in `GLSLANG_VALIDATOR`; it is skipped locally without
it and required in CI. `npx playwright install chromium` once before `test:browser`.

Porting another visualizer, and how the web stays in sync with Swift: [`docs/web-port.md`](../docs/web-port.md).
