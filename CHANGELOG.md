# NardukMusic changelog

NardukMusic ships on the narduk-libs repository `vX.Y.Z` tags (SwiftPM), not on npm.

## Unreleased

### Added

- `IntenseKind.audioTerrainMetal` ("Audio terrain (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port
  of the Canvas audio terrain: fourteen neon-crested ridges in perspective, painted far to near (the nearest six the
  live waveform history, the rest a ground-fixed noise landscape that scrolls with the travel), under a banded low
  sun, over a ground grid that rolls on the beat. Bass raises the central peak and swells the sun, mids the shoulders,
  highs a fine jitter at the edges; a kick and the beat lift the nearest ridge. No flash.
- `IntenseKind.pitchWheelMetal` ("Pitch wheel (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of
  the Canvas pitch wheel: twelve cylinder-lit glass petals (C at the top) that grow with each class, tip beads, an
  outer ring of class dots (hollow for sharps), a chord polygon through the strong classes, the key outlined with a
  spoke to a plasma ball in the tonic's color, rings on beat, kick and snare. Bass swells the ball and glow, highs
  sparkle on the tips.
- `IntenseKind.pianoRollMetal` ("Piano roll (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the
  Canvas piano roll: the notes as cylinder-lit glass bars on their pitch rows, hot at the strike and cooling along the
  tail, dimming with age as they flow into a lit piano keyboard where a sounding note flares and lights its key (the
  12 chroma rows as cells when the source gives no notes). Bass swells the playhead glow, highs light the dust, a kick
  flares the playhead.
- `IntenseKind.phosphorMetal` ("Phosphor (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the
  Canvas phosphor: a stereo-goniometer Lissajous burning into a CRT (the newest trace from the live waveform with a
  hot core and a wide bloom, five fading, shrinking older traces from the history), over a graticule with axes, rings
  and diagonals that lights under the beam, with a beat ring, a kick ring, a snare ring, dust and scanlines. Bass
  swells the center glow, highs light the outer graticule, a kick flares the trace.
- `IntenseKind.mirrorMetal` ("Mirror (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas
  mirror: 64 cylinder-lit neon slabs, bass at the center and highs at both edges (bass widens in a drop), with peak
  caps and rising embers, over a far skyline and a perspective neon floor that rolls once per beat, lit from below and
  reflecting the slabs, and a waveform horizon beam. A kick brightens the grid and glow; a snare streaks the horizon.
- `IntenseKind.padsMetal` ("Pads (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas
  pads: one lit glass pad per instrument (a 7 x 3 grid, role hues from the palette) with a bevel, a hot core, a spill
  into the gaps and neighbours and a shock ring on each hit, a spectrum backlight (bass left, highs right), a beat
  sweep each bar and empty sockets. A kick lights the panel.
- `IntenseKind.wobbleMeterMetal` ("Wobble meter (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of
  the Canvas wobble meter: a glossy dial with a chrome bezel, a neon cutoff arc and a needle with a fading tail that
  turns once per wobble cycle, beside segmented LED peak and RMS meters over a dim spectrum. Bass swells the dial's
  glow and hub, highs spark on the ticks, a kick flares the needle.
- `IntenseKind.scopeMetal` ("Scope (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas
  scope: the waveform as a phosphor beam on curved CRT glass, triggered on a rising zero crossing, with five receding
  history traces, a lit graticule and a snare sync bar. Bass swells the bloom, highs sparkle on the beam, a kick
  flares it.
- `IntenseKind.haloMetal` ("Halo (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas
  halo: 64 lit spectrum rays around a plasma core, the bass swelling the core and the rays on the left of the ring,
  the highs the right, a waveform ring with a chroma split, beat rings, a snare ring, peak ticks, zoom dust and shed
  sparks. Kicks flare the core.
- `IntenseKind.vortexMetal` ("Vortex (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): the Metal port of the
  Canvas vortex: a spiral galaxy of lit gas and shaded beads wound from the spectrum, bass at the core and highs at
  the rim, with a waveform accretion ring, a polar starfield turning at its own rate per ring, snare shock rings and a
  beat ring. A kick swells the core, a drop winds the arms tighter and a glitch splits them into two fringes.
- `IntenseKind.spectrumMetal` ("Spectrum (Metal)") in `NardukSoundVisuals` (narduk-libs#1569): the Metal port of the
  Canvas spectrum: 64 glass tubes of liquid light (a cylinder-lit body, specular streak, meniscus) with hue by band,
  floating peak beads, a mirror floor, a drifting echo row and dust. Bass and the kick swell the low tubes, highs
  stand tall, the snare throws a band of light up the tubes, the beat pulses the floor line, the drop widens them.
  Reads peaks through the new `IntenseAux` buffers.
- `SoundVisualizerKind.audioTerrain` ("Audio terrain") in `NardukSoundVisuals` (narduk-libs#1569): a neon wireframe
  landscape. Bass lifts the central ridges, mids the shoulders and highs the edge jitter; each older waveform-history
  row sits further away, and `travel` scrolls the grid. The beat lifts the nearest ridge; a drop brightens the palette
  and speeds the scroll.

## 0.4.1

Seeds that write new songs, musical visualizers, two more intense visualizers, a silent engine for apps that draw only,
and the Beat Blaster kids app. Everything is additive; the two enum cases below can break an exhaustive `switch`.

### Added

- `IntenseKind.sun` ("Sun") in `NardukSoundVisuals` (narduk-libs#1569): a Metal close-up star with a rotating,
  relief-lit granulated photosphere, sunspots, spicules, ridged corona streamers, snare-driven prominence loops and
  solar-wind sparks; bass swells the disc, mids churn the surface, highs fringe the limb, the kick flares it.
- `IntenseEffects` in `NardukSoundVisuals` (narduk-libs#1656): the shared MSL effects library every Intense shader
  compiles with (`fx*`: 3-D noise and `fxCylinder`, `fxRidge`, `fxNormal`/`fxLight`/`fxBall` lighting, `fxZoomLayer`/
  `fxCell` flying particles, `fxFlash`/`fxTonemap`/`fxVignette`). Liquid splash is its first consumer, pixel for pixel.
- `IntenseKind.liquidSplash` ("Liquid splash") in `NardukSoundVisuals` (narduk-libs#1569): a Metal splash of
  iridescent liquid filaments and glossy droplets flying out of a core, lit from a finite-difference normal. Bass
  sets the reach and the core, mids the warp, highs the spray; the kick swells the core, the snare throws a ring,
  the drop winds the streams. Flashes stay on the shared limiter.
- `SoundVisualizerKind.vortex` ("Vortex") in `NardukSoundVisuals` (narduk-libs#1569): a spiral galaxy whose three arms
  are the spectrum, bass beads at the core and highs at the rim, over a differentially rotating starfield. The
  waveform wraps the core as an accretion ring, a snare throws a shock ring, a kick swells the core, a drop winds the
  arms tighter, and a glitch splits them into the optical fringes.
- `SongSettings.variety` (0 ... 1, default 0.75; settings saved without it decode as 0, the original songs) and
  `SongSettings.varied(genre:seed:)`: a new seed now writes new chord progressions, hook motifs, drum kits (the genre
  keeps its backbeat), per-song drum tuning (the kick, snare and hat voices take a tune from the note's `formant`),
  wider patch parameters (formant, drive, vowel, keys timbre) and its own section lengths. `varied` also draws the
  tempo from the genre's range (`Genre.tempoRange`). `narduk-music render` takes `--variety` and `--varied`; scenarios
  take `variety` and `varied` (absent: 0, so existing scenarios render as before). Songs with `variety` 0 are bit for
  bit the ones before.
  Not yet done (narduk-libs#1617): half and double-time and alternative snare placement, instrument-entrance
  and breakdown-style variation, and a harmonic-rhythm and hook alignment check.
- Two musical visualizers in `NardukSoundVisuals` (narduk-libs#1573): `SoundVisualizerKind.pianoRoll`, a note waterfall,
  and `.pitchWheel`, the 12 pitch classes around a wheel with the key marked. Both draw from `SoundVisualState.musical`
  (`SoundMusicalState`: smoothed pitch classes, a 96-column note roll, a key estimate). SoundGallery
  shows both as tiles.
  Choosing them inside Data Beats is still open.
- `SoundFrame.chroma` (12 pitch classes, 0 ... 1), computed by `SpectrumAnalyzer` and `SoundAnalyzer` from the
  spectrum's peaks, placed by their true frequency. It gives raw audio (a file, a microphone) the pitch-class view.
- `MusicContext.heldNotes`, `noteCounts`, `keyPitchClass` and `keyIsMinor`, with `NoteSet`, `NoteCounters` and
  `NoteTracker` in `NardukMusicCore`. `DropEngine` fills the notes from the pitched notes it schedules (wobble, sub,
  keys and the guitars) on the main actor; the render thread is unchanged. All defaulted, so no existing value changes.
- Two intense visualizers (narduk-libs#1615): `IntenseKind.fractalDive` and `.synthwaveFlyover`, both through
  `IntenseFlashLimiter` and `IntenseMotion`. Frame rate on a device is not measured yet.
- `DropEngine.mutesHardwareOutput` (default `false`): mutes the speaker only. The recording and the `SoundFrameSource`
  keep the full signal, so a visualizer or an export can run silently. The audio graph is now source, capture
  mixer, main mixer, output (narduk-libs#1625).
- Beat Blaster, a kids app in the repo, on the library: Dream a Song builds its song through `SongRecipe`, with v3
  clipping fixes, a DROP plateau and punchier defaults (#1622, #1628, #1629).

### Fixed

- The pads visualizer fits small cards (`SoundVisualizers.PadLayout.fit`, narduk-libs#1612).
- Choosing Ambient in SoundGallery plays the ambient family song, not the classic demo loop (#1624).

### Shipped in 0.4.0, missing from its notes

- The first two intense Metal visualizers, hyperspace with lasers and fluid with glitch, with `IntenseFlashLimiter` (at
  most 3 flash onsets a second, a flash capped at 0.55 of white) and a `calm` option for Reduce Motion (#1619,
  narduk-libs#1615).
- SoundGallery's spectacle tiles poll the music-aware input, so they react to hits and sections (#1618).

### Source compatibility

New `SoundVisualizerKind` cases (`pianoRoll`, `pitchWheel`) and new `IntenseKind` cases (`fractalDive`,
`synthwaveFlyover`) break an exhaustive `switch` over either kind (a title, an icon or a picker in an app). No new
`Genre` or `Instrument` cases since 0.4.0. `SoundFrame` and `MusicContext` only gain defaulted fields.

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
