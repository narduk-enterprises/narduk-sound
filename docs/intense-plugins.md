# Drop-in Metal visualizer plugins (SoundGallery)

SoundGallery loads Metal visualizers from a folder at run time
(narduk-libs#1665), so a new visualizer is a file, not a rebuild. The Canvas
visualizers are retired: every built-in kind is a Metal shader, and plain MSL
text can be loaded where compiled Swift cannot (iOS forbids loading compiled
code).

## Drop one in

| Platform     | Folder                                                                                             |
| ------------ | -------------------------------------------------------------------------------------------------- |
| macOS        | `~/Library/Application Support/SoundGallery/Visualizers/` (the gallery's "Reveal" button opens it) |
| iOS / iPadOS | the app's Documents folder, visible in Files (AirDrop a `.metal` file to the phone)                |

Save a `.metal` file there. The running gallery picks it up within a second: an
added file is a new tile, a saved edit redraws the tile, a deleted file removes
it. No rebuild, no relaunch.

## The file

```metal
// title: Aurora
// fragment: auroraFragment

fragment float4 auroraFragment(
    IntenseVertexOut in [[stage_in]], constant IntenseUniforms &u [[buffer(0)]],
    constant float *spectrum [[buffer(1)]], constant float *wave [[buffer(2)]]) {
    float band = bandAt(spectrum, in.uv.x);
    float3 color = paletteAt(u, in.uv.x + u.resTime.z * 0.1) * (0.15 + band) * (1.0 - in.uv.y);
    color += u.extra.x * u.flashColor.rgb;  // the rationed flash, red-safe
    return float4(color, 1.0);
}
```

- `// title:` names the tile (default: the file name). `// fragment:` names the
  one fragment function to draw (default: the first `fragment float4 name(` in
  the file).
- The app prepends `IntenseShaderCommon` (the `IntenseUniforms` block,
  `IntenseVertexOut`, `hash11`, `hash21`, `vnoise`, `fbm`, `bandAt`,
  `paletteAt`) and `IntenseEffects` (the shared effects library), so a plugin
  uses them without an `#include`. Each file compiles into its own Metal
  library, so a clash between two plugins is impossible.
- The contract is fixed: buffer 0 is the uniform block, buffer 1 the 64-band
  spectrum, buffer 2 the waveform. Buffer 3 (`IntenseMotion`) is bound too, for
  a shader that wants the dive/flyover motion.
- Draw from `u.c0`/`u.c1`/`u.c2` (the palette) and `u.extra.y` (1 while a
  palette look is active) so the gallery's color knobs recolor it. Honour
  `u.extra.z` (intensity, lower in calm).

## When a file is broken

The tile shows the compiler's error (or "No fragment function named …") on a
dark card instead of a picture. Other tiles are unaffected. Fix the file and
save: the error clears.

## Safety

A plugin can strobe on its own, and `IntenseFlashLimiter` rations only the flash
the app hands in (`u.extra.x`). So every plugin tile runs through
`IntenseLumaWatchdog`: the tile is rendered to a texture, reduced to one pixel
of mean luma, and when that luma jumps up by more than 0.3 more than three times
in a second the tile is dimmed to a quarter until it has been calm for 1.5 s.
This is a backstop, not a license: a shipped plugin still goes through the
headless demo-still review (`NARDUK_INTENSE_DEMO_DIR`) like any other
visualizer.
