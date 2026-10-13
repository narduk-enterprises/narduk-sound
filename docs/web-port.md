# Porting a visualizer to the web

`web/` (`@narduk-enterprises/sound-web`) draws the Metal visualizers of `NardukSoundVisuals` in a browser with WebGL2
and falls back to Canvas2D. This is the repeatable process for porting one more, and the rules that keep the two sides
in sync. The Swift code is the source of truth; the web port follows it and never the other way round.

## What is shared, and how it stays in sync

| Swift                                           | TypeScript                     | Kept in sync by                                     |
| ----------------------------------------------- | ------------------------------ | --------------------------------------------------- |
| `SoundFrame`, `SpectrumAnalyzer`, `Loudness`    | `frame.ts`, `analysis.ts`      | `web/fixtures/sound-contract.json` (analysis)       |
| `SoundPalette`, `DefaultSoundPaletteProvider`   | `palette.ts`                   | the fixture (palettes)                              |
| `SoundVisualState` (the no-music path)          | `state.ts`                     | the fixture (12 state checkpoints)                  |
| `IntenseFlashLimiter`, `IntenseLumaWatchdog`    | `safety.ts`                    | the fixture (limiter, watchdog, flash colours)      |
| `SoundRenderBudget`                             | `budget.ts`                    | the fixture (budget, rates)                         |
| `IntenseUniforms`, `IntenseAux`                 | `uniforms.ts`                  | `web/test/shaders.test.ts` reads the Swift sources  |
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

Not ported yet (the web state behaves as Swift does with no `MusicContext`, so these stay at rest):
`SoundMusicInference`, the `MusicContext` paths (hits, sections, drops), the particle pool, and the musical state
(pitch classes, key, piano roll). A visualizer that needs them waits for that port.

## Porting one Metal visualizer

1. **Pick a look** whose Metal file needs only the uniforms, the spectrum, the waveform and the aux scalars or history
   (its `auxMask` in `IntenseKind` has no roll or particles bit).
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
