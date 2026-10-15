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
| `sun` | `Intense/Sun/SunShader.swift` |
| `flameSun` | `Intense/Promoted/FlameSunShader.swift` |
| `jellyfish` | `Intense/Jellyfish/JellyfishShader.swift` |
| `flower` | `Intense/Flower/FlowerShader.swift` |
| `liquidSplash` | `Intense/LiquidSplash/LiquidSplashShader.swift` |
| `bioluminescentSea` | `Intense/Promoted/BioluminescentSeaShader.swift` |
| `mirror` | `Intense/MirrorMetal/MirrorMetalShader.swift` |

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

Your own look (a station logo, say) is GLSL compiled after the shared prelude, with an optional image it samples as
`uImage` (premultiplied alpha, top row at `vUv.y = 0`). It comes first in the picker:

```ts
import { registerVisualizer } from "@narduk-enterprises/sound-web";

registerVisualizer({ id: "station", title: "Station", image: "/logo.png", glsl: `
uniform sampler2D uImage;
void main() { fragColor = vec4(texture(uImage, vUv).rgb * (0.5 + u.env.x), 1.0); }
` });
```

The Canvas2D fallback draws `halo` for a registered look.

Options: `renderer` `"auto" | "webgl2" | "canvas2d"`, `motion` `"auto" | "full" | "static"`, `palettes` (a
`SoundPaletteProvider`), `maxDevicePixelRatio`. Statuses: `idle`, `loading`, `playing`, `paused`, `still`, `silent`,
`error`.

## Draw from a recorded timeline (no audio)

When the sound cannot be read (Apple Music's DRM audio, a track playing elsewhere), draw from what a Mac recorded of it:
a `SoundTimeline` (`NSTL` v1, written by `SoundTimelineRecorder` in the Swift package) and the track's playhead.

```ts
import { SoundVisualizer, decodeSoundTimeline } from "@narduk-enterprises/sound-web";

const timeline = decodeSoundTimeline(await (await fetch(url)).arrayBuffer()); // throws SoundTimelineError on a bad container
const viz = new SoundVisualizer(canvas, { visual: "halo" });
viz.setTimeline(timeline, () => musicKit.currentPlaybackTime ?? null); // polled every frame: seconds, or null
viz.setAmbient(true); // with no timeline (and no audio): the quiet ambient drift
```

No tap or gesture is needed (nothing plays); the status is `playing` (or `still` under reduced motion). `playhead` is
seconds into the track, or `null` while paused or unknown: the last picture is held with its beat clock stopped, then
fades over about three seconds to the ambient drift (a slow breathing near 0.15 energy, no beat, no hits); a playhead at
or past `timeline.header.duration` counts as unknown. A seek in either direction fires no hits. `setTimeline` replaces a
playing audio source, `start()` replaces a timeline, and `setTimeline(null, ...)` returns to the ambient drift when
`setAmbient(true)` is on, else the visualizer goes `idle`. `viz.driver` says which one draws: `"audio"`, `"timeline"`,
`"ambient"` or `null`. A timeline URL on another origin must send `Access-Control-Allow-Origin`. The demo draws one with
`?timeline=<url>` (`?timeline=fixture` is a short built-in; `?ambient` is the drift alone).

## Music inference

A stream has no conductor, so the visualizer runs a `SoundMusicInference` over the analysis frames (a port of the Swift
class) and the state reacts to what it hears: kick, snare and hat hits, a tempo lock and beat phase, energy, sections
and drops. `state.snare`, `hat`, `impact`, `dropAmount`, `beatPulse` and `isRunning` move on real audio. To drive your
own state, call `state.update(frame, now, options, inference.update(frame))`. The analyzer's default `"apple"` window
matches what the Apple apps hear and what the inference was tuned on.

## Browser rules

- **iOS Safari:** audio starts only from a tap, so `start()` must run inside the click handler (the player's start
  button does this). The page asks for the `playback` audio session where the browser supports it, so the ring/silent
  switch does not mute the stream.
- **Streams (`StreamSource`):** an http(s) URL is fetched and decoded, not played through an `<audio>` element. WebKit
  (Safari, and every iOS browser) gives `createMediaElementSource` silence for a live, chunked stream such as an
  Icecast station even when CORS is right. So the bytes are split into MP3 or ADTS AAC frames, decoded with WebCodecs'
  `AudioDecoder` and scheduled gaplessly through the analyser. Other formats, and browsers without `AudioDecoder`, fall
  back to a media element. The server must still send `Access-Control-Allow-Origin`, since `fetch` needs it.
- **CORS:** without that header the stream cannot be read at all; an element fallback then plays it but the analyser
  reads zeros, and after 4 s of silence the status turns `silent` and says so.
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
