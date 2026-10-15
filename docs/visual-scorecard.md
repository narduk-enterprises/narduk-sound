# Visualizer scorecard

A headless way to put numbers on "the picture does not follow the music". It draws every visualizer the gallery shows
(the wobble tunnel, the shader pack, every built-in `IntenseKind`) offscreen over a window of a real recorded song, and
scores the pictures against the music that drove them. It measures only: no visualizer's look changes.

The code is `Tests/NardukSoundVisualsTests/`: `VisualScorecard.swift` (the maths, GPU-free),
`VisualScorecardRunTests.swift` (the renderer and the env-gated test), `ScorecardReport.swift` (`scores.csv` and
`scores.md`), and `VisualScorecardTests.swift` (unit tests of the maths, which always run).

## Running it

The test is skipped unless both variables are set. Songs are `SoundTimeline` files (`*.soundtimeline`, see
`SoundTimelineRecorder`), separated by `:`.

```sh
SCORE_TIMELINES=/path/a.soundtimeline:/path/b.soundtimeline SCORE_OUT=/some/scratch/dir \
  swift test -c release --filter scoreEveryVisualizerOverRecordedSongs
```

Use `-c release`: the per-frame pixel reduction is about ten times slower in a debug build. Measured on the laptop
(Mac15,10), two songs, both transforms, 44 visualizers, 60 s windows at 480x270 and 60 fps (176 runs, 633,600 frames):
1101 s in release; a debug build was extrapolated at about two hours from a 10 s smoke run, not measured.
Output, all in `SCORE_OUT`:

- `scores.md`: the readable tables (one per song and transform), the worst five per metric, and the identity versus
  rescale comparison.
- `scores.csv`: the same rows, one per (song, transform, visualizer), for plotting or diffing.
- `frames/<song>-<transform>-<visualizer>.csv`: the per-frame series (luma, spread, motion, hue, saturation, rms, kick,
  snare) the scores come from.
- `rows/`: one file per finished run; `SCORE_RESUME=1` skips a run whose row exists, so an interrupted run continues.
- `video/`: a silent H.264 per run when `SCORE_VIDEO=1`.

| Variable | Meaning | Default |
|---|---|---|
| `SCORE_TIMELINES`, `SCORE_OUT` | the songs and the output directory (both required) | |
| `SCORE_SECONDS` | window length | 60 |
| `SCORE_WINDOW_START` | window start in seconds, for every song | the window with the widest loudness range |
| `SCORE_SIZE` | render size | `480x270` |
| `SCORE_KINDS` | comma list of visualizer ids (`sun`, `pack.feedback`, `wobbleTunnel`, ...) | all |
| `SCORE_TRANSFORMS` | `identity`, `rescale` or both | both |
| `SCORE_VIDEO`, `SCORE_RESUME` | `1` to write mp4s, `1` to resume | off |

The unit tests of the maths run in a normal `swift test`.

## What is drawn

Each run draws 60 frames of warm-up (not scored: the state, the motion integrators and any feedback texture settle), then
`SCORE_SECONDS` of the song at 60 fps, `player.input(at: t)` per frame, through the same `SoundVisualState` and the same
`IntenseDrive`, `IntenseMotion` and flash limiter the live view uses. The default window is the 60 s of the song whose
1 s smoothed rms (dB, floored at -40, at least 10 s from either end of the song) has the widest p90 - p10, so it holds a quiet part and a loud part.

## The numbers

Per frame: mean luma (Rec. 601 weights, 0 to 1), luma spread (p90 - p10 of the pixel luma, 0 to 1), motion (mean absolute
RGB change from the previous frame, 0 to 1) and the hue and saturation of the mean colour.

- **Range use** (`luma_p10/p50/p90`, `spread_p10/p50/p90`). The 10th, 50th and 90th percentile over the window of the
  frame's mean luma and of its luma spread. Stuck dark: luma p90 under 0.04 (flag `dark`). Stuck bright: luma p10 over
  0.45 (`bright`). No contrast in the frame: spread p50 under 0.05 and almost no spread range (`flat`). Always busy:
  spread p10 over 0.35 (`busy`). A healthy picture has a wide p10 to p90 on both.
- **Hit response** (`kick_ratio`, `snare_ratio`, `*_lag_ms`, `*_hits`). A hit is a frame where the timeline's hit counter
  (`music.hitCounts` through `SoundTimelinePlayer.input(at:)`) for that instrument rose. `ratio` is the mean motion in
  frames 0 to 6 after the hit (0 to 100 ms) divided by the mean motion in all other frames. Above 1 the picture moves
  more right after a hit; about 1 it ignores them (flag `deaf-to-hits` when both are under 1.1). `lag_ms` is where the
  hit-aligned mean motion peaks within 300 ms (0 means the picture reacts in the frame of the hit). `-` when fewer than
  three hits. The hits are what the timeline's inference found in the audio, so a song whose inference finds few hits
  gives few hits here (see `*_hits`).
- **Loudness tracking** (`corr_rms_luma`, `corr_rms_motion`). Pearson correlation of the timeline's rms (dB) with the
  frame luma, and with the frame motion, both smoothed with a 0.5 s box. 1 follows the loudness; near 0 ignores it;
  negative dims as the music gets louder. `-` when the picture is flat. Flag `ignores-loudness` when both are under 0.1.
- **Section contrast** (`section_motion_ratio`, `section_luma_ratio`). The window is cut into 2 s pieces; the mean motion
  (or luma) in the loudest 20% of the pieces over the mean in the quietest 20%. 1 means a chorus looks like a verse; the
  further above 1, the more the picture changes with the section. A very large value usually means the quiet part is
  near-black and still, not that the loud part is rich: read it with `frozen`.
- **Motion steadiness** (`frozen_share`, `motion_p50`, `motion_p99`). `frozen_share` is the share of frames with motion
  under 0.0002 (about a twentieth of one 8-bit level); a high value is a picture that stops (flag `frozen` over 25%).
  `motion_p99` is the 99th percentile motion: a value far above `motion_p50` is strobing or jumps (flag `strobe` when
  p99 is over 0.12 and over six times p50).

## The input-transform hook

`VisualScorecard.Transform` is `(SoundVisualInput) -> SoundVisualInput`, applied to the player's input right before
`SoundVisualState.update`. The yardstick (rms, hit times) is always read from the raw input, so a transform changes the
picture and not what it is scored against. Three ship:

- `identity`: no change.
- `energy`: the music energy a re-recorded song would carry (see the caveats). Not run by default.
- `rescale`: per spectrum band, the song's p5 maps to 0 and its p98 to 1 (clamped), computed over the whole song's
  spectrum. A stand-in for an app's per-song contrast normalisation.

To score another remap, add a case in `VisualScorecardRunTests.scoreEveryVisualizerOverRecordedSongs` (the `transforms`
switch) that returns your closure, then run with `SCORE_TRANSFORMS=identity,<name>`. The report compares each extra
transform with `identity`.

## Caveats

- The numbers describe the picture the state produces from a timeline, not a live capture: the timeline stores the
  spectrum at 8 bits and the waveform at 32 points.
- Motion is a pixel difference, so a fast but uniform flicker and a slow wide change can score alike; read `motion_p99`
  and the frame series when a number looks odd.
- A timeline recorded before `SoundMusicInference` published its loudness as `music.energy` holds 0 there throughout,
  and a shader gated on `energy` draws almost nothing from one: Fireworks is a static night sky in every `identity`
  run of such a file. The audio is not needed to see what a re-recording would give: the `energy` transform replays the
  song's stored frames through a fresh `SoundMusicInference` and puts its energy into the context (`SCORE_TRANSFORMS=energy`).
  It hears the 8-bit, grid-rate frames and not the live ones, so it is a close stand-in for a re-recording, not the same.
- 480x270 is below the live drawable size; thin features can drop out, so compare visualizers on the same size only.
