# NardukMusic changelog

NardukMusic ships on the narduk-libs repository `vX.Y.Z` tags (SwiftPM), not on npm.

## Unreleased

### Added

- Two musical visualizers in `NardukSoundVisuals` (narduk-libs#1573): `SoundVisualizerKind.pianoRoll`, a note waterfall,
  and `.pitchWheel`, the 12 pitch classes around a wheel with the key marked. Both draw from `SoundVisualState.musical`
  (`SoundMusicalState`: smoothed pitch classes, a 96-column note roll, a key estimate). SoundGallery shows both as tiles.
- `SoundFrame.chroma` (12 pitch classes, 0 ... 1), computed by `SpectrumAnalyzer` and `SoundAnalyzer` from the spectrum's
  peaks, placed by their true frequency. It gives raw audio (a file, a microphone) the pitch-class view.
- `MusicContext.heldNotes`, `noteCounts`, `keyPitchClass` and `keyIsMinor`, with `NoteSet`, `NoteCounters` and
  `NoteTracker` in `NardukMusicCore`. `DropEngine` fills the notes from the pitched notes it schedules (wobble, sub,
  keys and the guitars) on the main actor; the render thread is unchanged. All defaulted, so no existing value changes.

### Source compatibility

New `SoundVisualizerKind` cases break an exhaustive `switch` over the kind (a title, an icon or a picker in an app).

## 0.4.0

The sound contract (`docs/sound-contract.md`): the engine publishes what any sound is doing and what the music knows
about itself, and the products around it land.

### Added

- `NardukSoundAnalysis`: any audio to a `SoundFrame` (spectrum, waveform, loudness) with `SoundAnalyzer`, `SPSCRing`,
  `SampleRing`, recent-sample and ring sources, and `AudioTapSource` on Apple hosts.
- `NardukSonify`: `StreamSonifier` turns a stream of numbers into `MusicSignal`s, online and in bounded memory.
- `NardukSoundVisuals`: `SoundVisualState`, the render budget (`SoundRenderBudget`) and the palette contract, with the
  visualizers on top: the seven Canvas visualizers (`SoundVisualizers.draw`, `SoundVisualizerView`), the Metal wobble
  tunnel, and the spectacle set (kick-driven particle field, beat tunnel kaleidoscope, a Metal shader pack with a
  feedback pass). The spectacle visualizers read `MusicContext` (snare ratchet, build arc).
- `SoundGallery`, a multiplatform app (macOS, iPad, iPhone) that draws the demo song, the mic or a file, with a song
  picker, full-screen tiles and the spectacle visualizers as tiles.
- `SongRecipe`: a song as plain fields, mapped to `SongSettings` and an energy script.
- Ambient: a genre family (swell and settle by signal level) with hall reverb, stereo delay, and pad and drone voices.
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
- `SongSettings.variety` (0 ... 1, default 0.75; settings saved without it decode as 0, the original songs) and
  `SongSettings.varied(genre:seed:)`: a new seed now writes new chord progressions, hook motifs, drum kits (the genre
  keeps its backbeat), per-song drum tuning (the kick, snare and hat voices take a tune from the note's `formant`),
  wider patch parameters (formant, drive, vowel, keys timbre) and its own section lengths. `varied` also draws the
  tempo from the genre's range (`Genre.tempoRange`). `narduk-music render` takes `--variety` and `--varied`; scenarios
  take `variety` and `varied` (absent: 0, so existing scenarios render as before). Songs with `variety` 0 are bit for
  bit the ones before.
- `DropEngine.makeSoundSource()`, the iOS audio session, interruptions and a longer lookahead.

### Deprecated

- `VisualizerFrame` and `DropEngine.latestFrame`. They still build, with a warning, and are now an adapter over
  `SoundFrame` and `MusicContext` (`VisualizerFrame(sound:music:previousHits:)`). Removed after 0.4.x.

### Source compatibility

New `Genre` cases break exhaustive switches in apps. Data Beats: `VisualKit.swift:22-30`, `Panels.swift:296`.
Wirewatcher: `DropPalette.swift:80`, `DropPanel.swift:253`, and `Instrument.glow` in `DropTrafficLayer.swift` for the
new guitar instruments.
The band genres add `rock`, `folk` and `funk` to the same switches (a title and a palette each).

## 0.3.0

First tag with the music products: `NardukMusicCore`, `NardukMusicDSP`, `NardukMusicRender`, `NardukMusicEngine` and the
`narduk-music` CLI, extracted from Wirewatcher.
