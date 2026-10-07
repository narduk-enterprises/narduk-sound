# NardukMusic changelog

NardukSound ships on this repository's `vX.Y.Z` tags (SwiftPM). Through v0.4.1 it
shipped on narduk-libs tags.

## Unreleased

### Added

- Recorded instruments (narduk-sound#34): `Resources/instruments.bin` (NVS2, 4.4 MB, 64 clips at 32 kHz) holds a soft grand piano, a steel drum, a sustained flute, an alto sax (two dynamics), a nylon guitar, small and large shakers, a tambourine, congas and a finger snap, from Salamander Grand Piano V3 (CC BY 3.0), jSteelDrum (Unlicense), VSCO 2 CE and VCSL (CC0), the University of Iowa samples and Freesound (CC0). New `KeysVoice.sampledPiano`, `sampledSteelDrum`, `sampledFlute`, `sampledSax`, `sampledNylonGuitar` and `sampledConga` on `.keys`, and `PercussionVoice.snap`, `shaker` and `tambourine` on `.snare`, `.hat` and `.openHat`, for any genre. They play from a fixed pool of 16 voices (the oldest is stolen and faded over 5 ms in a tail slot) with their own envelopes and a velocity law with no floor, on the light-duck sum (the hand percussion on the drums), never through the vocal room. Without the bank each falls back to a synth voice. `InstrumentBank.credits` has the credit lines an app shows (the piano's is required); sources, licence texts and changes are in `Resources/LICENSES/Instruments.md`. `scripts/instruments_fetch.py` and `scripts/build_instruments.py` rebuild the bank; the recordings are never committed.
- Tropical House, pass A: the hook is a recorded steel drum or flute (the existing variety draw picks), the chords a recorded piano over a quieter `pumpPad`, the breakdown hook a recorded sax or nylon guitar, and the drum tops a shaker, tambourine and finger snap. The drop runs in four-bar call and answer: the pluck plays two bars, sampled vocal chops answer in the third (picked from syllables sung near the note, so none is shifted far), and the fourth rests on the groove with a conga or two. One vocal role only: no choir pad, synth chops or sung line, no forced airy character, and no `voice`-cue chop. Its drop entry is `filterOpen` and its cut policy has no master cuts or stutters.
- The sampled singer's pool steals the oldest voice (the lowest slot on a tie) into a tail slot where it fades over 4 ms, instead of cutting it off.

- Per-track timbre variation (narduk-sound#33): each track written with variety above 0 draws a `TimbreMacro` (detune, cutoff, attack, decay, width, drive) from one of its genre's two or three designed `TimbreCharacter`s, inside a genre range that is narrow for tropical house, lofi and chill. The conductor stamps it on every note (`NoteParams.timbre`), and the drum, wobble, keys, pad and guitar voices apply it when a note starts; under a macro, drum hits take a seeded round-robin (a few cents of pitch, up to 8 % of decay, a fresh noise seed) and velocity moves brightness and attack. Variety 0 and notes without a macro render bit for bit as before.
- Measuring tools (#36): `narduk-music abtest` renders a same-seed, blind, loudness-matched A/B session (four seeds by four excerpts fixed by the plan, a hidden key with each render's fixture, and `MusicScenario.flags` for a change to switch on), `narduk-music abscore` unblinds the answers against the 9-of-12 bar, and `narduk-music samey` measures how alike a genre's songs are (notes, form, patches and MFCC timbre) into JSON. A report, never an evictor. Baseline in `docs/measurements/`.
- `Genre.tropicalHouse` ("Tropical House", 100 ... 112 BPM): a soft four-on-the-floor with an off-beat shaker and a light clap, a round off-beat sub, a marimba pluck hook (new `KeysVoice.marimba`) over pads that pump on their own slower sidechain (`KeysVoice.pumpPad`), airy vocal chops, and a gentle drop with no impact bias or grit. First version for listening.
- Library keys voices, for any genre (`KeysVoice`, played on `.keys`):
  - `panFlute`: a breathy pan flute, a soft sine under a band of breath that chiffs at the onset, with a delayed vibrato.
  - `steelDrum`: a steel pan, a bright FM strike settling into the octave and a sharp twelfth over an inharmonic ring.
  - `saxLead`: a sax-like lead, a breath-opened saw through two vowel formants, with a soft onset and a delayed vibrato.
  - `softPiano`: a warm soft piano for chords, round detuned sine partials, a felt hammer and a slow 25 ms attack.
  The melodic library voices (these and `marimba`) duck about 3 dB under the kick instead of the effects' 6 dB.
- Tropical House, take two: no whomps. The soft wobble under the off-beat sub, the drop impact, risers, tape stops,
  build snare rolls, the low vox chop and vox lead are gone; the sub no longer glides; `pumpPad` ducks about 3.7 dB
  instead of 16 dB; a `voice` cue answers with an airy pitched vocal chop; drums are softer (drop velocity ~22 % under
  house on the same seeds).
- `DropConductor.requestNextTrack(genre:)`: a smooth hand-over. The phrase plays out, its last bar carries the track's outro, and the new track (in the requested genre, if any) starts on the next phrase line. `setGenre` still cuts in at the next bar line.
- `NardukMusicPlayback` (Darwin): `NowPlayingBridge` publishes Now Playing info and maps play, pause, toggle and
  next track from the lock screen and HomePods to a `NowPlayingTransport`; `AirPlayPicker` wraps `AVRoutePickerView`.
  `docs/now-playing.md` has the `UIBackgroundModes: audio` requirement (narduk-sound#8).
- Song videos (`NardukSoundVisuals/Video`): `SoundVisualTimelineRecorder` logs
  what the lights drew from while a song records (the music context at 60 Hz,
  the light, its look, calm) into a compact `SoundVisualTimeline` file, and
  `SoundVideoExporter` turns the recorded audio plus that timeline into an
  `.mp4` with any Metal light drawn again offline (audio copied, not
  re-encoded). A light over the GPU budget draws smaller and is scaled up, as
  on a slow screen. Beat Blaster's My Songs shares with it (beat-blaster
  `docs/video-share.md` has the measurements).

### Changed

- Sections vary (#40): a build ramps bar by bar over its whole length (kick, hats, snare roll, then the kit opens like a filter) and lasts a second phrase only when the energy rose into it, and a track no longer hands over mid-build; a drop phrase is a call and a seeded response (bass rhythm variant, hat pattern swap, half-phrase drop-out), so no bar or pair repeats past four bars; an intro adds or rotates a layer each phrase after its second. Each genre arrives at a drop in one of a few forms (slam, filter opening, quiet pickup, band fill) instead of one riser, roll and impact for all, and vocal-plan cuts punctuate only some drop phrases per genre (tropical house's unchanged). Every genre golden moved.
- Fixes from Logan's Forever Loop flags (2026-10-07):
  - A queued drop out of an intro or breakdown now builds for one phrase first and drops on the line after. A drop straight out of an intro had one bar of lead-in.
  - The formant `vox` breakdown lead no longer plays in band genres (funk, rock, folk).
  - `SampleVoice` breath noise is band-limited to 2.4–7 kHz and fades in over 40 ms. It was flat to 22 kHz and gated hard per note, which read as crackle.
  - Goldens moved: chill, folk, funk, house, rock, synthwave, techno, tropicalHouse, ukGarage and the recipe fixture. Their Linux values come from the next Linux CI run.
- Long sets repeat themselves less. Drop phrases end on the track's own fills and the genre's fill bank; only a measured lull in the flow (not the default idle of a level-only source or a pinned hint) still forces a kick drop (it ended 100% of drop phrases before). Each next track's tempo walks across the genre's whole `tempoRange` by seed, 3 BPM to 8% from the last one, instead of sitting within a few BPM of the default.

## 0.5.0 (2026-10-07)

### Changed

- Moved from narduk-libs to its own repository, narduk-sound, with its history.
  The package identity is now `narduk-sound`: depend on
  `https://github.com/narduk-enterprises/narduk-sound` and name products with
  `package: "narduk-sound"`. The gallery app is under `Examples/SoundGallery`.

### Removed

- The Canvas visualizers in `NardukSoundVisuals` (narduk-libs#1569), each
  replaced by a Metal `IntenseKind` that takes its colors from the palette
  (`c0`/`c1`/`c2`; the default look is unchanged when no `SoundPaletteLook` is
  active). SoundGallery and Beat Blaster now show Metal tiles only. Data Beats
  pins a tag and is unaffected until it bumps.
  - `SoundVisualizerKind.spectrum`, `.scope`, `.wobbleMeter`, `.pads`,
    `.mirror`, `.halo`, `.phosphor`, `.pianoRoll`, `.pitchWheel`, `.vortex`,
    `.audioTerrain` (and `SoundVisualizers`, `SoundCanvasKit`): the
    `IntenseKind` of the same name (`IntenseKind.spectrum` ...
    `IntenseKind.audioTerrain`).
  - `ParticleFieldView` / `ParticleField`: `IntenseKind.particleField`
    ("Particle field").
  - `BeatKaleidoscopeView` / `KaleidoscopeRotation`: `IntenseKind.kaleidoscope`
    ("Beat kaleidoscope"; the snare ratchet of the Canvas view is replaced by a
    continuous spin).
  - SoundGallery's own Canvas cards: Spectrum -> `.spectrum`, Scope -> `.scope`,
    Levels -> `.wobbleMeter`, Radial -> `.vortex`.

### Added

- `IntenseKind.audioTerrain` ("Audio terrain") in
  `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas audio
  terrain: fourteen neon-crested ridges in perspective, painted far to near (the
  nearest six the live waveform history, the rest a ground-fixed noise landscape
  that scrolls with the travel), under a banded low sun, over a ground grid that
  rolls on the beat. Bass raises the central peak and swells the sun, mids the
  shoulders, highs a fine jitter at the edges; a kick and the beat lift the
  nearest ridge. No flash.
- `IntenseKind.pitchWheel` ("Pitch wheel") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas pitch wheel: twelve
  cylinder-lit glass petals (C at the top) that grow with each class, tip beads,
  an outer ring of class dots (hollow for sharps), a chord polygon through the
  strong classes, the key outlined with a spoke to a plasma ball in the tonic's
  color, rings on beat, kick and snare. Bass swells the ball and glow, highs
  sparkle on the tips.
- `IntenseKind.pianoRoll` ("Piano roll") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas piano roll: the notes as
  cylinder-lit glass bars on their pitch rows, hot at the strike and cooling
  along the tail, dimming with age as they flow into a lit piano keyboard where
  a sounding note flares and lights its key (the 12 chroma rows as cells when
  the source gives no notes). Bass swells the playhead glow, highs light the
  dust, a kick flares the playhead.
- `IntenseKind.phosphor` ("Phosphor") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas phosphor: a stereo-goniometer
  Lissajous burning into a CRT (the newest trace from the live waveform with a
  hot core and a wide bloom, five fading, shrinking older traces from the
  history), over a graticule with axes, rings and diagonals that lights under
  the beam, with a beat ring, a kick ring, a snare ring, dust and scanlines.
  Bass swells the center glow, highs light the outer graticule, a kick flares
  the trace.
- `IntenseKind.mirror` ("Mirror") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas mirror: 64 cylinder-lit neon
  slabs, bass at the center and highs at both edges (bass widens in a drop),
  with peak caps and rising embers, over a far skyline and a perspective neon
  floor that rolls once per beat, lit from below and reflecting the slabs, and a
  waveform horizon beam. A kick brightens the grid and glow; a snare streaks the
  horizon.
- `IntenseKind.pads` ("Pads") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas pads: one lit glass pad per
  instrument (a 7 x 3 grid, role hues from the palette) with a bevel, a hot
  core, a spill into the gaps and neighbours and a shock ring on each hit, a
  spectrum backlight (bass left, highs right), a beat sweep each bar and empty
  sockets. A kick lights the panel.
- `IntenseKind.wobbleMeter` ("Wobble meter") in
  `NardukSoundVisuals` (narduk-libs#1569): a Metal port of the Canvas wobble
  meter: a glossy dial with a chrome bezel, a neon cutoff arc and a needle with
  a fading tail that turns once per wobble cycle, beside segmented LED peak and
  RMS meters over a dim spectrum. Bass swells the dial's glow and hub, highs
  spark on the ticks, a kick flares the needle.
- `IntenseKind.scope` ("Scope") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas scope: the waveform as a
  phosphor beam on curved CRT glass, triggered on a rising zero crossing, with
  five receding history traces, a lit graticule and a snare sync bar. Bass
  swells the bloom, highs sparkle on the beam, a kick flares it.
- `IntenseKind.halo` ("Halo") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal port of the Canvas halo: 64 lit spectrum rays
  around a plasma core, the bass swelling the core and the rays on the left of
  the ring, the highs the right, a waveform ring with a chroma split, beat
  rings, a snare ring, peak ticks, zoom dust and shed sparks. Kicks flare the
  core.
- `IntenseKind.vortex` ("Vortex") in `NardukSoundVisuals`
  (narduk-libs#1569): the Metal port of the Canvas vortex: a spiral galaxy of
  lit gas and shaded beads wound from the spectrum, bass at the core and highs
  at the rim, with a waveform accretion ring, a polar starfield turning at its
  own rate per ring, snare shock rings and a beat ring. A kick swells the core,
  a drop winds the arms tighter and a glitch splits them into two fringes.
- `IntenseKind.spectrum` ("Spectrum") in `NardukSoundVisuals`
  (narduk-libs#1569): the Metal port of the Canvas spectrum: 64 glass tubes of
  liquid light (a cylinder-lit body, specular streak, meniscus) with hue by
  band, floating peak beads, a mirror floor, a drifting echo row and dust. Bass
  and the kick swell the low tubes, highs stand tall, the snare throws a band of
  light up the tubes, the beat pulses the floor line, the drop widens them.
  Reads peaks through the new `IntenseAux` buffers.
- `ShaderPackKind.meshWave` ("Mesh wave") in `NardukSoundVisuals`
  (narduk-libs#1569): a glowing wireframe heightfield. Bass raises the swells
  and deepens the trough, mids roll travelling waves, highs ripple the grid, and
  a kick sends a bounded ring plus a soft line glow. Calm slows the motion and
  drops the kick ripple.
- `ShaderPackKind.solarFlare` ("Solar flare") in `NardukSoundVisuals`
  (narduk-libs#1569): a molten sun on a black starfield. Bass swells the disc
  and pushes the corona out, mids curl the tendrils and churn the surface, highs
  sharpen the strands and spark the embers, and a kick sends a flare along the
  tendrils.
- `ShaderPackKind.oceanWaves` ("Ocean waves") in `NardukSoundVisuals`
  (narduk-libs#1569): layered Gerstner swells seen low from the side. Bass lifts
  the crests until they break, mids set the speed and how many layers roll,
  highs add glints and ripples, a kick pushes one swell through every layer, and
  a drop makes the sea steeper and foamier.
- `ShaderPackKind.fireworks` ("Fireworks") in `NardukSoundVisuals`
  (narduk-libs#1569): a night-sky fireworks show. Kicks launch shells whose size
  follows the bass; snare and hat crackle, highs twinkle, and mids pick the
  shell and the colour. A drop fires a bounded finale volley. Calm keeps a few
  slow shells and no volley.
- `SoundVisualizerKind.audioTerrain` ("Audio terrain") in `NardukSoundVisuals`
  (narduk-libs#1569): a neon wireframe landscape. Bass lifts the central ridges,
  mids the shoulders and highs the edge jitter; each older waveform-history row
  sits further away, and `travel` scrolls the grid. The beat lifts the nearest
  ridge; a drop brightens the palette and speeds the scroll.
- `ShaderPackKind.bassBlobs` ("Bass blobs"): raymarched glossy liquid metaballs.
  Bass swells and merges them, mids set the orbit, highs ripple the surface, and
  the kick squashes the mass with a rim glow; calm slows the orbit to 0.4 and
  drops the squash.
- Shader-pack look `aurora` ("Aurora curtains"): domain-warped light sheets and
  a starfield over a night sky (narduk-libs#1569).
- Shader-pack look `ShaderPackKind.auroraWaves` ("Aurora waves",
  narduk-libs#1569): silky multi-strand ribbons with an embedded equaliser over
  a night sky and a reflecting sea.
- Wordless female-range vocals (narduk-libs#1641): `Instrument.vocal` (a choir pad of three detuned voices, a solo lead
  or a solo pad) and `Instrument.vocalChop` (a short one-shot that opens from an "oo"), formant-synthesised: a band-limited
  saw through three formant filters (alto and soprano tables), breath noise, a vibrato that starts late and a scoop up
  to the pitch, with a small room of their own. `NoteParams.voice` packs the vowel (`VocalVowel`: ah, oh, oo, eh, ee,
  mm) and style (`VocalStyle`) via `NoteParams.vocalVoice(_:style:)`; `formant` is the register (0 alto ... 1 soprano)
  and `drive` the breathiness. Scenario notes take `vowel`, `style` and `register`. Nothing is added to an arrangement
  and a song without vocals renders bit for bit as before.
  Seven voice feels (`VocalFeel`: classic, airy, pop, dark, soul, ethereal, toy; `NoteParams.vocalVoice(_:style:feel:)`,
  scenario note field `feel`) vary the formants, breath, vibrato, attack, voice count and room of the same synth; classic
  is the default and renders exactly as before. `power` is a chest-mix belt with a little grit; `runs` is tuned for
  `VocalRun`, an ornament any held vocal note can take (scenario note field `run`): it holds, then sings a pentatonic,
  minor or blues run up, down or in waves over an octave or more in sixteenths or thirty-seconds.
- A master cut (narduk-libs#1641): `Instrument.cut`, an effect on the finished mix that fires on an exact sample: `stutter`
  (beat repeat, `amount` pitches it up and fades it), `gate` (a trance gate), `reverse` and `chop` (the last eight slices
  re-sequenced from a seed, a few left silent), over a `CutDivision` slice (quarter ... thirty-second). Use it from a
  note (`NoteParams.cut`, scenario fields `cut`, `division`, `cutSeed`, `drive`), from the arrangement, or live with
  `DropEngine.cut(_:division:steps:amount:seed:)`, which starts on the next audio buffer. With `SongSettings.variety`
  above 0 a song may add wordless vocals (a pad, a chop hook) and a stutter into each drop; at 0 (the default) nothing is
  added and every render is bit for bit as before.
- A sampled female voice (narduk-libs#1641): `Instrument.vocalSample` plays recorded ahs, oohs, ehs and ees (straight, vibrato
  and belt), syllable chops and sung scale runs of one VocalSet singer (CC BY 4.0, credit in the README and
  `Resources/LICENSES`), 2 MB of 16-bit PCM in the package resources, key-mapped from a root every three semitones,
  looped with a baked crossfade, pitched within a few semitones of its root and played by a pooled sampler voice into
  the vocal room. `NoteParams.sampleVoice(_:technique:kind:)` packs vowel, `SampleTechnique` and `SampleKind` (sustain,
  chop, run); scenario notes take `technique` and `kind`, `run` (VocalRun) works on sampled notes too, and the master cut
  stutters, gates and reverses it like everything else. `SampleBank.shared` loads at synth construction, never on the
  audio thread.
- A vocal processor and a song-driven vocal line (narduk-libs#1641): `NoteParams.expression` carries a
  `VocalExpression` (vibrato depth and rate, scoops, falls and bends, a vowel morph between two banks, formant shift,
  breath, grit, pitch snap, detune, and throws: tempo-synced echo, telephone/radio/muffled filter, reverse swell,
  stretch or freeze; presets `torch`, `power`, `robot`, `telephone`, `morphing`, `frozen`; scenario notes take
  `expression`). With `SongSettings.variety` above 0 the vocal follows the chords (chord tones on strong beats, in the
  key, call and response with the hook, stacked harmonies, a few on-grid chops, a reverse swell into each drop).
  `VocalFX.riser` / `VocalFX.stutterIntoDrop` and `DropEngine.scheduleVocalRiser` / `scheduleStutterIntoDrop` are for a
  drop arranger. A note without an expression renders exactly as before.

## 0.4.1

Seeds that write new songs, musical visualizers, two more intense visualizers, a
silent engine for apps that draw only, and the Beat Blaster kids app. Everything
is additive; the two enum cases below can break an exhaustive `switch`.

### Added

- `IntenseKind.sun` ("Sun") in `NardukSoundVisuals` (narduk-libs#1569): a Metal
  close-up star with a rotating, relief-lit granulated photosphere, sunspots,
  spicules, ridged corona streamers, snare-driven prominence loops and
  solar-wind sparks; bass swells the disc, mids churn the surface, highs fringe
  the limb, the kick flares it.
- `IntenseEffects` in `NardukSoundVisuals` (narduk-libs#1656): the shared MSL
  effects library every Intense shader compiles with (`fx*`: 3-D noise and
  `fxCylinder`, `fxRidge`, `fxNormal`/`fxLight`/`fxBall` lighting,
  `fxZoomLayer`/ `fxCell` flying particles, `fxFlash`/`fxTonemap`/`fxVignette`).
  Liquid splash is its first consumer, pixel for pixel.
- `IntenseKind.liquidSplash` ("Liquid splash") in `NardukSoundVisuals`
  (narduk-libs#1569): a Metal splash of iridescent liquid filaments and glossy
  droplets flying out of a core, lit from a finite-difference normal. Bass sets
  the reach and the core, mids the warp, highs the spray; the kick swells the
  core, the snare throws a ring, the drop winds the streams. Flashes stay on the
  shared limiter.
- `SoundVisualizerKind.vortex` ("Vortex") in `NardukSoundVisuals`
  (narduk-libs#1569): a spiral galaxy whose three arms are the spectrum, bass
  beads at the core and highs at the rim, over a differentially rotating
  starfield. The waveform wraps the core as an accretion ring, a snare throws a
  shock ring, a kick swells the core, a drop winds the arms tighter, and a
  glitch splits them into the optical fringes.
- `SongSettings.variety` (0 ... 1, default 0.75; settings saved without it
  decode as 0, the original songs) and `SongSettings.varied(genre:seed:)`: a new
  seed now writes new chord progressions, hook motifs, drum kits (the genre
  keeps its backbeat), per-song drum tuning (the kick, snare and hat voices take
  a tune from the note's `formant`), wider patch parameters (formant, drive,
  vowel, keys timbre) and its own section lengths. `varied` also draws the tempo
  from the genre's range (`Genre.tempoRange`). `narduk-music render` takes
  `--variety` and `--varied`; scenarios take `variety` and `varied` (absent: 0,
  so existing scenarios render as before). Songs with `variety` 0 are bit for
  bit the ones before. Not yet done (narduk-libs#1617): half and double-time and
  alternative snare placement, instrument-entrance and breakdown-style
  variation, and a harmonic-rhythm and hook alignment check.
- Two musical visualizers in `NardukSoundVisuals` (narduk-libs#1573):
  `SoundVisualizerKind.pianoRoll`, a note waterfall, and `.pitchWheel`, the 12
  pitch classes around a wheel with the key marked. Both draw from
  `SoundVisualState.musical` (`SoundMusicalState`: smoothed pitch classes, a
  96-column note roll, a key estimate). SoundGallery shows both as tiles.
  Choosing them inside Data Beats is still open.
- `SoundFrame.chroma` (12 pitch classes, 0 ... 1), computed by
  `SpectrumAnalyzer` and `SoundAnalyzer` from the spectrum's peaks, placed by
  their true frequency. It gives raw audio (a file, a microphone) the
  pitch-class view.
- `MusicContext.heldNotes`, `noteCounts`, `keyPitchClass` and `keyIsMinor`, with
  `NoteSet`, `NoteCounters` and `NoteTracker` in `NardukMusicCore`. `DropEngine`
  fills the notes from the pitched notes it schedules (wobble, sub, keys and the
  guitars) on the main actor; the render thread is unchanged. All defaulted, so
  no existing value changes.
- Two intense visualizers (narduk-libs#1615): `IntenseKind.fractalDive` and
  `.synthwaveFlyover`, both through `IntenseFlashLimiter` and `IntenseMotion`.
  Frame rate on a device is not measured yet.
- `DropEngine.mutesHardwareOutput` (default `false`): mutes the speaker only.
  The recording and the `SoundFrameSource` keep the full signal, so a visualizer
  or an export can run silently. The audio graph is now source, capture mixer,
  main mixer, output (narduk-libs#1625).
- Beat Blaster, a kids app in the repo, on the library: Dream a Song builds its
  song through `SongRecipe`, with v3 clipping fixes, a DROP plateau and punchier
  defaults (#1622, #1628, #1629).

### Fixed

- The pads visualizer fits small cards (`SoundVisualizers.PadLayout.fit`,
  narduk-libs#1612).
- Choosing Ambient in SoundGallery plays the ambient family song, not the
  classic demo loop (#1624).

### Shipped in 0.4.0, missing from its notes

- The first two intense Metal visualizers, hyperspace with lasers and fluid with
  glitch, with `IntenseFlashLimiter` (at most 3 flash onsets a second, a flash
  capped at 0.55 of white) and a `calm` option for Reduce Motion (#1619,
  narduk-libs#1615).
- SoundGallery's spectacle tiles poll the music-aware input, so they react to
  hits and sections (#1618).

### Source compatibility

New `SoundVisualizerKind` cases (`pianoRoll`, `pitchWheel`) and new
`IntenseKind` cases (`fractalDive`, `synthwaveFlyover`) break an exhaustive
`switch` over either kind (a title, an icon or a picker in an app). No new
`Genre` or `Instrument` cases since 0.4.0. `SoundFrame` and `MusicContext` only
gain defaulted fields.

## 0.4.0

The sound contract (`docs/sound-contract.md`): the engine publishes what any
sound is doing and what the music knows about itself, and the products around it
land.

### Added

- `NardukSoundAnalysis`: any audio to a `SoundFrame` (spectrum, waveform,
  loudness) with `SoundAnalyzer`, `SPSCRing`, `SampleRing`, recent-sample and
  ring sources, and `AudioTapSource` on Apple hosts.
- `NardukSonify`: `StreamSonifier` turns a stream of numbers into
  `MusicSignal`s, online and in bounded memory.
- `NardukSoundVisuals`: `SoundVisualState`, the render budget
  (`SoundRenderBudget`) and the palette contract, with the visualizers on top:
  the seven Canvas visualizers (`SoundVisualizers.draw`, `SoundVisualizerView`),
  the Metal wobble tunnel, and the spectacle set (kick-driven particle field,
  beat tunnel kaleidoscope, a Metal shader pack with a feedback pass). The
  spectacle visualizers read `MusicContext` (snare ratchet, build arc).
- `SoundGallery`, a multiplatform app (macOS, iPad, iPhone) that draws the demo
  song, the mic or a file, with a song picker, full-screen tiles and the
  spectacle visualizers as tiles.
- `SongRecipe`: a song as plain fields, mapped to `SongSettings` and an energy
  script.
- Ambient: a genre family (swell and settle by signal level) with hall reverb,
  stereo delay, and pad and drone voices.
- `MusicContext` and `HitCounters` (`NardukMusicCore`): the beat clock, section,
  energy, thresholds, `dropQueued` and per-instrument monotonic hit counters.
- `DropEngine.latestSound` (`SoundFrame`) and `latestMusic` (`MusicContext`),
  published ~60 Hz and not observed. `DropEngine.conductor` carries the
  conductor's energy, thresholds and queued drop into `latestMusic`.
  `DropSynthCore.hitCounters` counts every hit on the render thread without
  allocating; unlike `takeHits()` nothing is cleared, so a consumer that skips
  frames loses no hit.
- Genres: techno, UK garage, synthwave and lo-fi hip hop. Instruments: acoustic,
  electric and bass guitar and strums. Harmony: major modes, chord voicings and
  comping patterns.
- Band genres: `rock`, `folk` and `funk` (`Genre.family == .band`). Each has its
  own tempo range, drum grammar and progressions; the guitars carry the part
  (power-chord 8ths, the folk strum with a fingerpicked hook, muted 16th
  scratch) over a bass guitar, with no wobble, sub or pad.
- `DropEngine.makeSoundSource()`, the iOS audio session, interruptions and a
  longer lookahead.

### Deprecated

- `VisualizerFrame` and `DropEngine.latestFrame`. They still build, with a
  warning, and are now an adapter over `SoundFrame` and `MusicContext`
  (`VisualizerFrame(sound:music:previousHits:)`). Removed after 0.4.x.

### Source compatibility

New `Genre` cases break exhaustive switches in apps. Data Beats:
`VisualKit.swift:22-30`, `Panels.swift:296`. Wirewatcher:
`DropPalette.swift:80`, `DropPanel.swift:253`, and `Instrument.glow` in
`DropTrafficLayer.swift` for the new guitar instruments. The band genres add
`rock`, `folk` and `funk` to the same switches (a title and a palette each).

## 0.3.0

First tag with the music products: `NardukMusicCore`, `NardukMusicDSP`,
`NardukMusicRender`, `NardukMusicEngine` and the `narduk-music` CLI, extracted
from Wirewatcher.
