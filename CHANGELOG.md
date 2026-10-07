# NardukMusic changelog

NardukMusic ships on the narduk-libs repository `vX.Y.Z` tags (SwiftPM), not on npm.

## 0.4.0

The sound contract (`docs/sound-contract.md`): the engine publishes what any sound is doing and what the music knows
about itself, and the products around it land.

### Added

- `NardukSoundAnalysis`: any audio to a `SoundFrame` (spectrum, waveform, loudness) with `SoundAnalyzer`, `SPSCRing`,
  `SampleRing`, recent-sample and ring sources, and `AudioTapSource` on Apple hosts.
- `NardukSonify`: `StreamSonifier` turns a stream of numbers into `MusicSignal`s, online and in bounded memory.
- `NardukSoundVisuals`: `SoundVisualState`, the render budget and the palette contract.
- `MusicContext` and `HitCounters` (`NardukMusicCore`): the beat clock, section, energy, thresholds, `dropQueued` and
  per-instrument monotonic hit counters.
- `DropEngine.latestSound` (`SoundFrame`) and `latestMusic` (`MusicContext`), published ~60 Hz and not observed.
  `DropEngine.conductor` carries the conductor's energy, thresholds and queued drop into `latestMusic`.
  `DropSynthCore.hitCounters` counts every hit on the render thread without allocating; unlike `takeHits()` nothing is
  cleared, so a consumer that skips frames loses no hit.
- Genres: techno, UK garage, synthwave and lo-fi hip hop. Instruments: acoustic, electric and bass guitar and strums.
  Harmony: major modes, chord voicings and comping patterns.
- Band genres: `rock`, `folk` and `funk` (`Genre.family == .band`). Each has its own tempo range, drum grammar and
  progressions; the guitars carry the part (power-chord 8ths, the folk strum with a fingerpicked hook, muted 16th
  scratch) over a bass guitar, with no wobble, sub or pad.
- `DropEngine.makeSoundSource()`, the iOS audio session, interruptions and a longer lookahead.

### Deprecated

- `VisualizerFrame` and `DropEngine.latestFrame`. They still build, with a warning, and are now an adapter over
  `SoundFrame` and `MusicContext` (`VisualizerFrame(sound:music:previousHits:)`). Removed after 0.4.x.

### Source compatibility

New `Genre` cases break exhaustive switches in apps. Data Beats: `VisualKit.swift:22-30`, `Panels.swift:296`.
Wirewatcher: `DropPalette.swift:80`, `DropPanel.swift:253`.
The band genres add `rock`, `folk` and `funk` to the same switches (a title and a palette each).

## 0.3.0

First tag with the music products: `NardukMusicCore`, `NardukMusicDSP`, `NardukMusicRender`, `NardukMusicEngine` and the
`narduk-music` CLI, extracted from Wirewatcher.
