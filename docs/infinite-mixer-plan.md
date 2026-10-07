# narduk-sound 0.6 and the infinite mixer: survey and plan

Status: proposal for Logan, 2026-10-07. Written by the master session from three
read-only survey lanes (audio, visuals, apps; reports in
`~/.agents/programs/narduk-sound/reports/2026-10-07-survey-s*.md`) with the
load-bearing claims re-checked by hand. Nothing here is decided until Logan says
so; open choices are in the last section. The previous program's plan and
retrospective live in data-beats (`docs/sound-visuals-plan.md`,
`docs/sound-visuals-retro.md`).

The survey was run against narduk-libs main on the morning of 2026-10-07. That afternoon Logan approved splitting the
package out: it is now this repository, narduk-sound (`packages/modules/narduk-music/swift/*` became the root,
SoundGallery is `Examples/SoundGallery`), Beat Blaster is the private repo `narduk-enterprises/beat-blaster`, and the
split commit is tagged `v0.5.0`. Paths below are the new ones; narduk-libs issue and PR numbers keep their
`narduk-libs#` prefix. "0.6" is the first release after the split.

## What we have (2026-10-07, narduk-sound `v0.5.0`, the split commit)

| Target                | Files | Lines  | Tests (lines) | What it is                                                                                                |
| --------------------- | ----- | ------ | ------------- | --------------------------------------------------------------------------------------------------------- |
| NardukMusicCore       | 20    | 6,339  | 3,000         | Genres, instruments, conductor, arrangements, drops, vocals, harmony, recipes, determinism                |
| NardukMusicDSP        | 20    | 4,408  | 2,326         | Voices, effects, limiter, reverb, step clock, sample bank, the real-time `DropSynthCore`                  |
| NardukMusicEngine     | 4     | 638    | 212           | `DropEngine` (AVAudioEngine host), recorder, session policy (Darwin only)                                 |
| NardukMusicRender     | 3     | 650    | 595           | Offline deterministic render, goldens, scenarios                                                          |
| NardukSonify          | 3     | 549    | 266           | Stream to music                                                                                           |
| NardukSoundAnalysis   | 8     | 679    | 276           | Any audio to a `SoundFrame` (FFT, bands, chroma, loudness, taps, rings)                                   |
| NardukSoundVisuals    | 62    | 10,813 | 3,910         | 32 Intense Metal kinds plus plugins, 11 Spectacle shader packs, the wobble tunnel, state, palette, budget |
| beat-blaster (repo)   | 37    | 7,035  | (in files)    | Kids' iPad and iPhone app, TestFlight, Catalyst flag on; private repo since the split                     |
| Examples/SoundGallery | 18    | 1,715  | (in files)    | Multiplatform gallery, prompt to song, plugin folder; the package's own test bench                        |
| data-beats (repo)     |       |        |               | macOS app, kit, CLI; pins 0.4.1                                                                           |

Two days of lanes produced a library that already does the hard musical work: a
deterministic conductor with endless tracks, genre switches at bar lines with
lead-ins and outros, 13 genres plus the ambient family, guitars and vocals, a
lock-free real-time core with an allocation gate, per-platform goldens, and
50-odd Metal visualizers behind one palette contract. The apps proved it on
devices. What follows is what stands between that and an adult product that
plays all evening on the HomePods.

## Ten findings that matter most

Each was reported by a lane and re-verified in the master session unless marked
"lane only".

1. **The live engine never applies the conductor's tempo switch.**
   `DropConductor.lastSwitch` is consumed only by `OfflineRenderer` and by Data
   Beats' two pump copies (`Studio.swift:367`, `Sonifier.swift:480`). Beat
   Blaster and SoundGallery switch genre and keep the old tempo.
2. **Four copies of the conductor-to-synth pump** (Beat Blaster `SongPlayer`,
   SoundGallery `SongPlayer`, Data Beats `Studio` and `Sonifier`, plus
   `DropEngineDemo`), each with the same step-rewind restart hack. The next app
   would be the fifth.
3. **Any output or sample-rate change restarts the song from step 0.**
   `DropEngine.observeConfigurationChanges` (`DropEngine.swift:427-441`) calls
   `start()`, which builds a new core and sets `currentStep = 0` (`:219`,
   `:238`). An AirPlay route change is exactly this event. Unplugged headphones
   call `stop()`; so would a HomePod dropping for a second.
4. **No AirPlay, background audio, Now Playing or remote commands anywhere.**
   The session is `.playback` with no route sharing policy; no
   `UIBackgroundModes`; both apps pause audio on `.background`. AirPlay adds
   about two seconds of output latency, which the session reports but nothing
   reads; the visuals would run two seconds ahead of the sound.
5. **Transitions are cuts, not mixes.** Outros and lead-ins exist, but there is
   no overlap of two arrangements, no tempo ramp (tempo jumps to the genre
   default at the next bar), no key-aware track choice, and master gain fades
   are a `Task` loop in the app, not a sample-accurate ramp.
6. **Live tuning is only partly live.** The master filter glides over 20 ms and
   the controls are atomics, but `SongSettings` applies at track boundaries,
   there is no ramped instrument mute, and there is no single `LiveControls`
   type for energy, blend, tempo, key, density, mood, variety, instruments and
   FX.
7. **Three Metal render stacks** (Intense, Spectacle, WobbleTunnel) each carry
   their own renderer, MTKView wrapper, vertex shader, uniform struct and
   sizing; the `fx.x` uniform means "flash" in one and "calm" in another; only
   Intense has the flash limiter and only plugins have the luma watchdog. About
   342 KB of shader source compiles eagerly at start and one bad shader disables
   all of Intense (`IntenseRenderer.swift:121-127`).
8. **There is no mood axis and no sync clock in the visuals.** Calm is a
   boolean, the 11 promoted kinds ignore the palette unless an "extra" uniform
   is set, `SoundFrame` has no host time (`AudioTapSource.swift:59` drops the
   `AVAudioTime`), and the thermal and low-power budget tier is computed but
   never consulted (the apps pass a constant frame rate). narduk-libs#1701
   (merged, in `v0.5.0`) adds an adaptive render-scale governor and a frame
   meter; it is the base for budget work, not a duplicate of it.
9. **Adding a Genre or Instrument compiles and plays wrongly.** `Genre.family`,
   `DropArranger.style(of:)`, `Track.swift:405` and `DropSynthCore.trigger`
   absorb a new case through `default:`; `IntenseKind.allCases` is a hand-kept
   array; `ShaderPackKind` and Data Beats' pickers are exhaustive switches that
   break on a version bump.
10. **Repo hygiene.** 548 Beat Blaster design files, 98 MB, were tracked in
    the public narduk-libs repo (derived `ios/` and `out/` included); the split
    moved them with the app into the private beat-blaster repo, where the
    derived folders are still tracked. Three apps,
    three build setups, two bundle prefixes, no privacy manifest or
    entitlements, and stale docs (the plan and retro still say A7 is open; Data
    Beats' README says 0.3.0 and six genres).

Also worth knowing (lane only, not re-measured): per-sample `tanf`, `exp2f`,
`sinf` and `cosf` in the SVF, wobble, sub and vocal voices are the main CPU risk
for a phone playing for hours; `RoomReverb` runs per sample for the snare; there
is no CPU-budget test, no click test around switches, and no per-genre loudness
measurement.

## Part 1: the library program (narduk-sound 0.6)

Waves are ordered by what the new app needs first. Sizes are S (under a day), M
(one to two days), L (three days or more) for one Sonnet lane. Architecture
choices marked (Opus) want an Opus high design pass before the lane starts.

### Wave L0: unblock (S each, start today)

- Done by the split: narduk-libs#1701 is merged and the package stands alone
  at `v0.5.0`. Consumers (data-beats, wirewatcher, buildbeat, beat-blaster)
  repoint their dependency URL to narduk-sound when they next bump.
- Cut `v0.6.0-alpha.1` after L1 so the new app pins a tag from day one.
- In beat-blaster, stop tracking the derived `design/assets/ios` and `out`
  folders: keep the xcassets the build needs and regenerate the rest from
  `raw/`.
- Fix the stale docs: plan and retro close-out lines (A7 is merged as
  data-beats#6 and #9), Data Beats README (0.4.1, 13 genres, six tabs), the Data
  Beats `ci.yml` header, the visualizer skill's Canvas references, the
  CHANGELOG's `*Metal` names.
- File one issue per wave item below with the repo's `area:music` label; link
  them to a new portal board (`narduk-infinite-mixer`) that supersedes
  `narduk-sound-visuals` for this work.

### Wave L1: play forever on any output (the new app's first dependency)

| Id  | Change                                                                                                                                                                                                                                                                                                                                                                                                                     | Target                                      | Size |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | ---- |
| R1  | `ConductorDriver`: one live pump that owns the cursor and lookahead, applies `lastSwitch` tempo, genre and key, exposes play, pause, resume, skip, and is driven by the audio clock (not a main-thread timer) so it survives the screen being off. Replaces all four app pumps and `DropEngineDemo`. (Opus design)                                                                                                         | Engine + Core                               | M    |
| R2  | Configuration change keeps the music: rebuild the AVAudioEngine graph, keep `DropSynthCore` and `currentStep`, re-prime the ring.                                                                                                                                                                                                                                                                                          | Engine                                      | S-M  |
| R3  | `SessionPolicy` v2: `.playback` with `.longFormAudio` route sharing (AirPlay 2 multi-room), a reroute policy (keep playing on route config change, pause on headphone unplug, resume per `InterruptionResponse` with the cursor intact), `mediaServicesWereReset` handling, and a public `RouteInfo` with `outputLatency` (session latency plus IO buffer on iOS, `presentationLatency` on macOS) and an `isAirPlay` flag. | Engine                                      | M    |
| R4  | `NowPlayingBridge` (`MPNowPlayingInfoCenter` title, genre, elapsed; `MPRemoteCommandCenter` play, pause, next mapped to the driver) and a SwiftUI `AirPlayPicker` wrapping `AVRoutePickerView`; document the `UIBackgroundModes: audio` requirement.                                                                                                                                                                       | Engine (or a small `NardukMusicApp` target) | S-M  |
| R13 | Per-genre loudness measurement test and a master trim table so dubstep and ambient sit at the same level in a set.                                                                                                                                                                                                                                                                                                         | DSP + Render                                | S    |

Proof: a device test on hog and an iPad with HomePods: play ten minutes with the
screen off, switch outputs twice, take a phone call; the step counter never
resets and the lock screen controls work. Add an `OfflineRenderer` test that a
conductor-driven render changes tempo at the switch bar.

### Wave L2: mix and tune (the app's second dependency)

| Id  | Change                                                                                                                                                                                                                                                                                                                                                      | Target        | Size |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | ---- |
| R5  | Bar-aligned, integer-exact tempo ramp (`DropSynthCore.setTempoRamp(toBPM:overBars:)`) so 128 to 140 glides over a phrase.                                                                                                                                                                                                                                   | DSP           | M    |
| R6  | `TransitionPlan { kind, bars, tempoCurve, gainCurve, keyPolicy }` and a `TrackBlender`: the outgoing track's tails and drums overlap the incoming lead-in with per-group gain automation; key-compatible next-track choice (circle-of-fifths distance in `Harmony`). Start with three kinds: cut (today), filter-sweep blend, long crossfade. (Opus design) | Core + DSP    | L    |
| R7  | `ParameterSmoother` for every live control and a `LiveControls` model: energy, genre blend weights, tempo range, key, density, mood, variety, instrument mutes with fade, FX sends, master gain ramp. Density and variety take effect at the next phrase; everything else glides.                                                                           | DSP + Core    | M-L  |
| R9  | `SessionLog` of step-stamped control events and replay in `OfflineRenderer`, so a saved "scene" (seed plus log) renders the same set again and can be shared.                                                                                                                                                                                               | Core + Render | M    |
| R8  | Benchmark target (CPU per block per genre on the laptop and on device), then block-rate coefficient updates for the SVF, wobble, sub and vocal voices with a golden refresh.                                                                                                                                                                                | DSP           | M    |

Proof: a discontinuity test (max sample-to-sample delta around a switch under
the limiter ceiling), a 30-minute simulated set with 12 transitions and no step
reset, and the benchmark numbers in the PR.

### Wave L3: one renderer, a mood axis, and sync

| Id  | Change                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Target             | Size |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ---- |
| V1  | Host-time plumbing: capture `AVAudioTime.hostTime` in the tap, stamp `SoundFrame` and `MusicContext`, and add a delay line of frames and contexts (3 s deep) at the `SoundVisualInput` closure, fed by `RouteInfo.outputLatency` plus a user offset.                                                                                                                                                                                                                                                                                                                                                                                                                    | Analysis + Visuals | M    |
| V2  | One `VisualRenderer` (Opus design): one MTKView wrapper, one vertex shader, one `VisualUniforms` superset (time, beat phase, bands, chroma, envelopes, palette ramp, `mood`, `motionScale`, extras), a lazily compiled pipeline cache keyed by kind id with per-kind failure isolation, one drawable sizer and governor hook, flash limiter and luma watchdog for every kind. Spectacle and the tunnel become kinds behind a thin adapter; `FeedbackSurface` becomes an optional pass. Delete `ShaderPackView`, `WobbleTunnelView`, `WobbleTunnelDrawableSizer` and the two extra uniform fills. Kinds become data (id, title, fragment, capabilities), not enum cases. | Visuals            | L    |
| V3  | A continuous `mood` scalar (0 still, 1 flashy) that every shipped kind honours (time scale, pulse gain, flash ceiling, saturation, density, camera), smoothed over seconds, driven by energy and section with a user bias; Reduce Motion clamps it; palette becomes the default for the promoted kinds.                                                                                                                                                                                                                                                                                                                                                                 | Visuals            | M    |
| V4  | Clock-wrap hardening (time mod 3600 and beats mod 4096 in the tunnel uniforms hitch once an hour in a forever app), idle dimming after N minutes without touch, thermal and low-power tiers wired to the governor from #1701, a prebuilt metallib or lazy compile for the 342 KB of shader source.                                                                                                                                                                                                                                                                                                                                                                      | Visuals            | M    |
| V5  | Analysis fixes: dt-scaled attack and release, a reused waveform buffer, a beat-phase and onset field in `SoundFrame` for non-generated audio, a momentary loudness measure for level matching.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Analysis           | S-M  |
| V6  | Curate the adult set: 8 to 10 calm-capable, palette-driven kinds (aurora, ocean waves, bioluminescent sea, jellyfish, black hole, tidal observatory or mercury loom, flower, sun, fractal dive for depth, one party kind) reviewed on a TV through the headless render loop; the instrument displays and strobe-prone kinds stay in the gallery.                                                                                                                                                                                                                                                                                                                        | Visuals + review   | M    |

Proof: a delay-line test (a frame stamped at t renders at t plus latency),
per-kind mood and palette tests, a long-run clock test, GPU timing on an iPad 10
and the TV Mac through the frame meter.

### Wave L4: guards and lifting (can run beside L2 and L3)

| Id  | Change                                                                                                                                                                                                                                                                                                                               | Target               | Size |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------- | ---- |
| R10 | Compile-time Genre and Instrument guard: remove the `default:` branches, one `Genre.profile` table behind a single switch, `DropSynthCore.trigger` over a `SynthVoiceKind` enum, and a test rendering one bar for every genre and instrument pair that asserts a note and non-silence. Same for `IntenseKind.allCases` completeness. | Core + DSP + Visuals | M    |
| R11 | Remove the deprecated `VisualizerFrame`, `latestFrame`, `previousHits`; move `DemoPattern` out of DSP.                                                                                                                                                                                                                               | DSP + Engine         | S    |
| R12 | Lift pure app code into Core: `SoundProfile` and the sound enums, `EffectSettings.apply(to:)`, `BandPart`, `GuitarPart` chapters, the mash-up morph; delete the app copies and rename the app-side `SongRecipe`.                                                                                                                     | Core + Apps          | M    |
| R14 | A `NardukMusicApp` target for UI-adjacent pieces every app needs: transport state, recordings store and player, palette and look controls, visualizer catalog and picker, a Mac-aware layout test harness, the silent-mode helper. Beat Blaster and SoundGallery adopt it.                                                           | New target           | M-L  |

### What this does to the apps

- Beat Blaster deletes `SongPlayer` and most of `BlasterAudio` (about 950 lines)
  for the driver, session policy and `NardukMusicApp`; its ship behaviour (no
  AI, DROP, Mash it up, the tray) is unchanged. It gets background-safe audio
  for free.
- SoundGallery deletes its `SongPlayer` and `GalleryModel` engine code, keeps
  prompt-to-song, the palette bar and the plugin folder (macOS first; iOS plugin
  acceptance by App Store review is unproven).
- Data Beats repoints to narduk-sound and bumps from 0.4.1 to 0.6 once V2 lands (its Canvas picker switches
  break on the bump; the kinds-as-data change fixes that for good), and replaces
  its two pumps with the driver.
- Wirewatcher pins 0.4.0 and is untouched until it chooses to bump.

## Part 2: the new app

Working title to be chosen by Logan; the repo placeholder below is
`infinite-mixer`. Everything in this part is a proposal.

### What it is

An endless, self-mixing set of generated music for adults, on iPhone, iPad and
Mac, that you tune rather than operate. It is on when you want music in the
house and nobody wants to DJ. The screen is a living artwork when it is on, and
the music keeps going when it is off. No AI dependency in the core experience
(the on-device prompt-to-song from SoundGallery is an optional extra, Logan's
call).

### Setup (decided by the surveys, pending Logan's yes)

- A private repo `narduk-enterprises/infinite-mixer` like data-beats: a SwiftPM
  kit (`MixerKit`, headless, Swift Testing) plus a CLI for offline set
  rendering, and one xcodegen app target with native
  `supportedDestinations: [iOS, macOS]` (SoundGallery's model, not Catalyst),
  iOS 18 and macOS 15, pinned to a narduk-sound tag.
- Beat Blaster's signing: automatic, team FVSY7CFC3S, bundle
  `com.nardukenterprises.<name>`, TestFlight internal group.
- Info: `UIBackgroundModes: audio`, `NSMicrophoneUsageDescription` only if the
  room-listening feature ships, `PrivacyInfo.xcprivacy`, entitlements file,
  `LSApplicationCategoryType` music, no `UIRequiresFullScreen`.
- CI: data-beats' private Apple-pool workflow with the build lock; kit tests,
  app build for both destinations, unit and layout tests on an iPhone and iPad
  simulator, a Mac test run.
- No tracked generated assets: the icon and any renders come from the asset-pack
  skill into a private assets location and only the xcassets the build needs are
  committed.

### Information architecture

- **Stage.** Full-bleed visualizer, minimal chrome that fades after a few
  seconds, a quiet caption (current genre, key, session time, "drifting toward
  house" one bar before a transition), transport (play or pause, next, hold
  this), the AirPlay picker, and the mood dial. On Mac: a window that goes
  fullscreen on a TV, menu commands and space to play. On iPad: the stage with a
  persistent right-hand Tune column in landscape. On iPhone: the stage with a
  bottom tray that opens Tune as a sheet.
- **Tune.** One scrolling column of groups, each with a sensible default and an
  "auto" position:
  - Energy: a slider plus auto (the mixer wanders).
  - Genre blend: the 13 genres and the ambient family as weighted chips the
    mixer stays within.
  - Tempo and key: a range and "follow genre"; key lock for people who care.
  - Density, variety, swing.
  - Mood: one dial that drives both the music's intensity bias and the visual
    mood axis.
  - Instruments: band mask with sound profiles (bass, keys, kit, guitar, pads,
    voice) from the lifted `SoundProfile`.
  - FX: echo, filter, stutter, reverb size.
  - Look: palette preset or random, visualizer set, motion scale, idle dim
    timer.
  - Advanced (behind a disclosure): seed, steps per bar, bars per phrase,
    transition style, AirPlay sync offset.
- **Scenes.** "Keep this" snapshots the current `LiveControls`, seed and
  `SessionLog` as a named scene; scenes replay deterministically, render offline
  to M4A through the kit CLI, and share as a small file. Optional rolling record
  of the last N minutes (the recorder's support for a rolling buffer is unknown;
  measure first).
- **Settings.** Output and background behaviour, Now Playing, visual budget,
  accessibility (Reduce Motion, flash ceiling), credits (VocalSet CC BY 4.0 if
  vocals ship).
- **Screen-off and AirPlay mode.** Audio continues through the background mode;
  visuals stop at 0 fps when not visible; the lock screen and HomePod controls
  map to play, pause and next; the visual delay line keeps the Mac-on-TV picture
  in time with HomePods playing from the same device. On macOS the system picker
  does not drive a custom AVAudioEngine, so the Mac path is "pick the HomePods
  as the system output in Control Center" with the app reading the output
  device's presentation latency; the Mac on the TV is the natural house hub, the
  iPhone the remote.

### Milestones

| Milestone                        | Needs  | Done when                                                                                                                                                                                            |
| -------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M1 Plays forever on the HomePods | L0, L1 | Stage with play, pause, next and the AirPlay picker; background audio; Now Playing; a ten-minute screen-off AirPlay session on hog with two route changes and no restart; TestFlight internal build. |
| M2 Tune                          | L2     | The Tune column drives `LiveControls` without clicks; genre blend and energy auto-wander; the first blended transition; scenes save and replay.                                                      |
| M3 The picture                   | L3     | The curated kinds with the mood dial, palette presets, delay-line sync measured on a TV, idle dim, governor on an iPad 10.                                                                           |
| M4 Ship                          | all    | Rolling record, share, privacy manifest, external TestFlight, App Store metadata.                                                                                                                    |

M1 is achievable with L1 alone because the conductor already plays endless
tracks and cuts between genres; the mix quality improves in M2 without changing
the app's shape.

### Lanes and models

- Opus high: the three design passes (driver, transition layer, unified
  renderer) as short written designs before code.
- Sonnet 5.5 scoped lanes: every R and V item above, one per PR, file-disjoint
  by target; L1 is one wave of four lanes, L2 and L3 can run beside each other,
  L4 fills gaps. The app's M1 lane starts when L1 has a tag.
- Grok visualizer lanes through the `narduk-sound-visualizer` skill for V6
  polish once V2 lands.
- One `verify` pass only for V2 (large deletion) and R3 (background audio and
  session behaviour).

### Measure before building

Unknowns from the surveys that a lane should settle on device in the first day,
each a half-day:

1. Does the main-thread pump keep running in the background with the screen off
   on iOS? (Decides how urgent the audio-clock driver is for M1.)
2. Does `AVAudioSession.outputLatency` or `presentationLatency` report AirPlay's
   two seconds on hog and on the Mac?
3. CPU per block per genre on hog and an iPad 10, and startup compile time of
   the Intense library.
4. Does the recorder support a rolling buffer?

## Part 3: open choices for Logan

1. **Name and repo.** A private `narduk-enterprises/<name>` repo like
   beat-blaster and data-beats (apps no longer live inside the package repo);
   the name is the open part.
2. **Transition first.** Ship M1 with cuts (today's conductor) and blend in M2
   (recommended), or hold M1 for the blend.
3. **Prompt to song.** In as an optional extra on devices that have the model,
   or out of this app entirely.
4. **Plugins on iOS.** Keep `.metal` drop-ins macOS-only (recommended) or risk
   App Store review on iOS.
5. **Catalyst.** Drop Beat Blaster's never-built Catalyst flag in favour of the
   native multiplatform target the new app uses, or keep it.
6. **The design assets.** Keep the 98 MB in beat-blaster now that it is
   private, or drop the derived folders and regenerate them.
