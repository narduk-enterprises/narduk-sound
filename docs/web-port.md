# Porting a visualizer to the web

`web/` (`@narduk-enterprises/sound-web`) draws the Metal visualizers of `NardukSoundVisuals` in a browser with WebGL2
and falls back to Canvas2D. This is the repeatable process for porting one more, and the rules that keep the two sides
in sync. The Swift code is the source of truth; the web port follows it and never the other way round.

## What is shared, and how it stays in sync

| Swift                                           | TypeScript                     | Kept in sync by                                     |
| ----------------------------------------------- | ------------------------------ | --------------------------------------------------- |
| `SoundFrame`, `SpectrumAnalyzer`, `Loudness`    | `frame.ts`, `analysis.ts`      | `web/fixtures/sound-contract.json` (analysis)       |
| `SoundPalette`, `DefaultSoundPaletteProvider`   | `palette.ts`                   | the fixture (palettes)                              |
| `SoundVisualState` (with and without music)     | `state.ts`                     | the fixture (12 state + 33 music checkpoints)       |
| `SoundMusicInference`, the `MusicContext` it makes | `inference.ts`              | the fixture (hit, lock and section events, checkpoints) |
| `IntenseFlashLimiter`, `IntenseLumaWatchdog`    | `safety.ts`                    | the fixture (limiter, watchdog, flash colours)      |
| `SoundRenderBudget`                             | `budget.ts`                    | the fixture (budget, rates)                         |
| `IntenseUniforms`, `IntenseAux`                 | `uniforms.ts`                  | `web/test/shaders.test.ts` reads the Swift sources  |
| `SoundTimeline` (NSTL v1), `SoundTimelinePlayer` | `timeline.ts`                  | `web/fixtures/sound-timeline.json` (bytes and player states) |
| each `*MetalShader.swift`                       | `src/shaders/<id>.ts`          | the recorded `metalSha256` of the Metal file        |

`Tests/NardukSoundVisualsTests/WebContractFixtureTests.swift` runs scripted signals through the Swift types and
compares them with the fixture; `web/test/contract.test.ts` runs the same scripts through the TypeScript and compares
with the same fixture. A change on either side that moves a number fails one of the two. When a Swift change is
deliberate, regenerate the fixture and port the change:

```sh
NARDUK_WRITE_WEB_FIXTURES=1 swift test --filter WebContractFixtureTests   # rewrites web/fixtures/sound-contract.json
cd web && npm test                                                         # now fails until the TypeScript follows
```

One known platform difference: Swift's `SpectrumAnalyzer` window is `vDSP_HANN_NORM`, 0.8165 (1 - cos), on Apple and
0.5 (1 - cos) on Linux, so Apple's bands read 4.26 dB hotter (#67). The fixture is written on Linux, so the web's
`SoundAnalyzer(rate, 1 / 60, "portable")` matches it; the web's default, `"apple"`, matches what the visualizers draw on
Apple, and `contract.test.ts` pins the difference against the macOS run. The Swift test compares spectrum and chroma
only on the portable path.

## Music: hits, tempo, sections

A web source has no conductor, so `SoundVisualizer` runs one `SoundMusicInference` per source over the analyzer's frames
(reset when the source changes) and hands the `MusicContext` to `SoundVisualState.update(frame, now, options, music)`,
which is what Swift does for a file or a loopback device. `inference.ts` is a line-for-line port: spectral-flux onsets in
three band ranges (kick, snare, hat), the 50 Hz onset grid and autocorrelation tempo with its lock and switch rules, the
kick phase pull, energy, sections and drops, and silence. `state.ts` has the `MusicContext` branches of the Swift state:
the clock follows `step`, the hit counters fire the `kick`, `snare`, `hat`, `glitch`, `laser` and `impact` envelopes
with the flash, shake and chroma triggers, sections blend the palette and set the tunnel speed, and the energy and
section history rings fill. A frame with no `music` argument keeps the old no-music path exactly.

What the fixture pins (`music` in `sound-contract.json`): a scripted drum machine fed as `SoundFrame`s (bands that rise
on each hit; `DrumFrames` in `SoundMusicInferenceTests.swift`): eight loud seconds at 128 BPM, a quiet breakdown,
silence, drums again. The frame each kick, snare, hat and impact fired on, the frame the tempo locked on and each
section change are **events and compared exactly**; the rest (step, energy, tempo, the state's envelopes, palette and
clock) at checkpoints every 40 frames, to 2e-3 (Swift accumulates in Float, the TypeScript rounds the same accumulators
with `Math.fround`). The script is frames, not audio, so it does not depend on the window below and runs on every
platform; `test/inference.test.ts` runs audio through the analyzer instead (kick, snare, hat, a 120 BPM lock, the
synthetic source) with both windows.

Inference's onset floors are in band units, so it must read the same window as the Swift side that tuned them: the web's
default `SoundAnalyzer(rate)` is the `"apple"` window (4.26 dB hotter than Linux, #67), which is what the Apple apps
hear, and the demo keeps it. Regenerating the fixture on a Mac keeps the Linux `analysis` section (the writer reads it
back instead of overwriting it with Apple's bands).

## Timelines: `SoundTimeline`, `SoundTimelinePlayer`, `setTimeline`

A page that cannot hear a track (Apple Music is DRM audio) draws it from a timeline a Mac recorded with
`SoundTimelineRecorder`. `timeline.ts` is a port of `SoundTimeline.swift` (the NSTL v1 container: `decodeSoundTimeline`,
planar little-endian blocks read through a `DataView`, the same four decoding errors as `SoundTimelineError.reason`) and
of `SoundTimelinePlayer.swift` (interpolated spectrum, chroma and levels; nearest-sample waveform restored from 32 points
to 512 with the same Catmull-Rom; the beat clock between samples; hit counters that only go up and add nothing across a
seek; the end held and stopped). Arithmetic rounds to `Float` where Swift's does, so the two agree to under 1e-6.

`Tests/NardukSoundVisualsTests/WebTimelineFixtureTests.swift` records a timeline from a scripted drum machine (frames,
not audio, so Linux and macOS record the same) and writes `web/fixtures/sound-timeline.json`: the NSTL bytes and what the
Swift player returns for a script of 533 playback times (an off-grid 144 Hz run, a repeated time, a forward jump, a
backward seek, the end and past it, a negative time and NaN). `web/test/timeline.test.ts` decodes the same bytes and
replays the same times: hit counters, step, section and flags exactly, frames and contexts to 2e-6. Regenerate after a
deliberate Swift change:

```sh
NARDUK_WRITE_WEB_FIXTURES=1 swift test --filter WebTimelineFixtureTests   # rewrites web/fixtures/sound-timeline.json
cd web && npm test
```

`SoundVisualizer.setTimeline(timeline, playhead)` feeds the player's frame and `MusicContext` through the same
`SoundVisualState.update` and `ShaderInputs.fill` as live audio (`TimelineFeed` in `feed.ts`); `setAmbient(true)` draws
`AmbientDrift` (`ambient.ts`, the sound-tv drift: energy 0.15 plus or minus 0.035, no beat, no hits). Behaviour with no
playhead, precedence between audio, timeline and ambient, and reduced motion are in `web/README.md`. The state's `now` is
the animation clock; the playhead only indexes the player, so a seek never looks like time running backwards. A new feed
calls `state.resetMusic()` so the state adopts its hit counters without firing, and the silence watch is off (a recorded
intro can be silent).

LiveDrive applies to timelines. A recorded timeline is the same compressed signal a stream is: on four stored Apple
Music tracks (3 to 5 minutes, 60 Hz, played through `SoundVisualState` and `ShaderInputs.fill` at 60 fps) the state's
energy sat in 0.41 ... 0.44 (swing p98 - p5 0.03 ... 0.11), where LiveDrive widens it to 0.37 ... 0.44 swing. Bands that
already move (a kick band, p98 - p5 0.7) stay the same, bands that sit near a level gain 2 ... 3 times the swing. The
only timeline-specific rule is `LiveDrive.apply(..., amount)`: the feed passes 1 while the timeline plays, falls to 0
with the fade to the ambient drift, and is 0 for the ambient feed, so the quiet breathing is never stretched. sound-tv
instead stretches each song with a `ContrastMap` (per-song percentiles, needs the whole timeline in hand); that is not
ported.

## Live drive: `LiveDrive` (web only, not in the contract)

Broadcast audio is compressed, so the state's `energy`, `wild` and band levels barely move on a live stream (KZFR:
`u.wobble.z` stayed within 0.27 ... 0.33). The state is the Swift contract, so the web does not change it. `live.ts`
(`LiveDrive`) runs after `ShaderInputs.fill` in `SoundVisualizer.step` and rewrites only the drive channels the shaders
already read: `u.env` kick, snare and hat (a sharper kick and snare curve, the hat lifted to full scale), `u.wobble.z`
energy and `u.misc.x` wild (read against their own running mean and deviation, plus a short lift on a hit), and the
spectrum row and `Aux.peaks` (each band's deviation from its running mean scaled up to a target, never down). It never
touches the flash path (`u.fx`, `u.extra`), passes silence and calm through, and is a no-op on a source that already
moves. A consumer that calls `ShaderInputs.fill` itself, not through `SoundVisualizer`, calls `LiveDrive.apply` after
it. `node scripts/measure-reactivity.mjs` (live stream or `--synthetic`) logs the state's value ("before") beside the
drawn one ("after") from the same run, plus the photosensitivity watchdog's dimming share.

Not ported (no web renderer draws them): the particle pool and the pads, and the musical state (pitch classes, key,
piano roll). A visualizer that needs them waits for that port.

## Porting one Metal visualizer

1. **Pick a look** whose Metal file needs only the uniforms, the spectrum, the waveform and the aux scalars or history
   (its `auxMask` in `IntenseKind` has no roll or particles bit, and its fragment binds no `motion` buffer 3: the
   fractal dive and the synthwave flyover wait for `IntenseMotion` to be ported).
2. **Add `web/src/shaders/<id>.ts`** exporting a `VisualizerPort`: `id`, `title`, `metalSource` (the repo path of the
   Swift file), `metalSha256` (`sha256sum` of that file) and `glsl` (the fragment body, after `FRAGMENT_PRELUDE`).
   Copy the Metal functions and its fragment function, then translate them with the table below. Keep the names,
   the constants and the order of operations, so a later Metal diff applies line by line.
3. **Helpers** the look calls from `IntenseShaderCommon.swift` (`fx*`, `hash*`, `vnoise`, `fbm`, `bandAt`,
   `paletteAt`) live once in `src/shaders/common.ts`; port a missing one there, not into the look.
4. **Register it** in `src/shaders/index.ts` (`VISUALIZERS`).
5. **Add a Canvas2D drawing** for it in `src/canvas2d.ts` (a simplified picture is fine; it only has to show the
   sound when WebGL2 is missing).
6. **Prove it**: `npm run check` (types, unit tests, glslang compile, build), then `npm run test:browser` (draws,
   animates, pauses, holds still under reduced motion; screenshots in `web/test-results/`). Look at the screenshot
   next to the Sound Gallery's.
7. **Add it** to the browser smoke list in `web/scripts/browser-smoke.mjs` and to the README's table.

When the Metal file changes later, the sync test fails with the new hash: diff the Metal file
(`git log -p -- <metalSource>`), apply the same change to the GLSL, and update `metalSha256`.

## MSL to GLSL ES 3.00

| Metal                                                   | GLSL                                                                   |
| ------------------------------------------------------- | ---------------------------------------------------------------------- |
| `float2/3/4`, `float3x3`, `int2`                        | `vec2/3/4`, `mat3`, `ivec2`                                            |
| `constant IntenseUniforms &u [[buffer(0)]]`             | the global `uniform IntenseUniforms u` (same field names)              |
| `constant float *spectrum [[buffer(1)]]`, `spectrum[i]` | `spectrumAt(i)` (row 0 of the `uData` texture)                         |
| `waveform[i]`                                           | `waveAt(i)` (row 1)                                                    |
| `aux[i]` (buffer 4)                                     | `auxAt(i)` (row 2; indices from `IntenseAux.swift`)                    |
| `history[i]` (buffer 5)                                 | `historyAt(i)` (rows 3 and 4)                                          |
| `in.uv`                                                 | `vUv` (same top-left origin; the present pass flips for the screen)    |
| `fragment float4 name(...)` returning a colour          | `void main()` writing `outColor`                                       |
| `atan2(y, x)`                                           | `atan(y, x)`                                                           |
| `fmod(x, y)`                                            | `x - y * trunc(x / y)` (GLSL `mod` floors, so it differs below zero)   |
| `saturate(x)`                                           | `clamp(x, 0.0, 1.0)`                                                   |
| `thread float &x` parameter                             | `out float x` (or `inout` when it is read first)                       |
| `static`, `inline`, `constexpr`                         | removed (`const` for a constant)                                       |
| `pow(x, 2.0)`                                           | `sq(x)`: GLSL `pow` is undefined for a negative base                   |
| `pow(x, y)` with `x` that may be negative               | `pow(abs(x), y)` or `pow(max(x, 0.0), y)`, as the Metal result implies |
| `1.0h`, `half`                                          | `1.0`, `float` (`half`, `in`, `out`, `sample`, `input` are reserved)   |
| integer `uint` arithmetic                               | `int` unless it relies on wrap-around                                  |
| array literal `float a[3] = {…}`                        | `float a[3] = float[3](…)`                                             |

The test `has no Metal left in it` catches the common leftovers (`float3`, `constant`, `thread`, `atan2(`, `in.uv`,
`[[`, `static`, `fmod(`, `saturate(`, `pow(…, 2.0)`), and glslang compiles every port (`npm test`; required when `CI` is set, wired into CI by #65).

## The frame rules the web keeps

- **Flashing (WCAG 2.1 AA 2.3.1):** the flash uniform passes through `FlashLimiter` (at most 3 a second, 0.55 peak,
  a red-safe tint), and the presented picture through `LumaWatchdog` (a luma jump over 0.3 lowers the gain to 0.25
  for 1.5 s). WebGL2 reads the scene's 1×1 mip back asynchronously; Canvas2D reads an 8×8 probe.
- **Reduced motion:** `prefers-reduced-motion: reduce` (or `motion: "static"`) draws one still that changes only when
  the picture would, never an animation.
- **Frame budget:** `SoundRenderBudget` (60, 30 reduced, 0 hidden) and `FrameGovernor`, which lowers the backing
  resolution and then the rate when frames run long, and starts low-end phones at 30 fps and a 1.5× pixel ratio cap.

## The public demo

<https://visualizers.nard.uk> is the demo page (`web/demo`) served by the static-assets Worker
`narduk-sound-visualizers` on the narduk-enterprises Cloudflare account, attached to the nard.uk zone as a custom
domain (`web/wrangler.jsonc`). It plays the KZFR live stream, a local file or any CORS-enabled URL. Deploy from `web/`
with the repository's registered deploy route (operation `cloudflare-worker-deploy`):

```sh
nvault run -p cloudflare -e prd -c narduk-enterprises-narduk-sound-worker-deploy -- sh -c \
  'CLOUDFLARE_API_TOKEN="$NARDUK_SOUND_WORKER_DEPLOY_CF_TOKEN" CLOUDFLARE_ACCOUNT_ID="$NARDUK_SOUND_WORKER_DEPLOY_CF_ACCOUNT_ID" npm run deploy'
```

A lane guest gets that config with `scripts/lane-credential grant cloudflare-worker-deploy` (agent-infrastructure).
