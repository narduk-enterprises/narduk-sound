# NardukSound contract

Status: design, 2026-10-06 (narduk-libs#1567, phase A1 of the NardukSound
program). Plan, layers and phases: `docs/sound-visuals-plan.md` in
narduk-enterprises/data-beats. This document is what A2 (analysis), A3 (sonify),
A4 (gallery), A5 (port) and A6 (music) build against. A type or rule here
changes only by editing this file in a PR.

Logan's framing: data, data streams, music creation and visualizations from that
music; and "it doesn't have to be music". So a visualizer must work from a
`SoundFrame` alone, and use a `MusicContext` only when one is present.

## 1. Products

Three new products of the existing package
(`packages/modules/narduk-music/swift`), one gate and one release tag. The empty
targets landed first (narduk-libs#1580) so no later lane edits the root
`Package.swift`.

| Product               | Depends on                               | Owns                                                                                                                       |
| --------------------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `NardukSoundAnalysis` | nothing                                  | `SoundFrame`, `SpectrumAnalyzer`, `SoundLevel.decibels`, `SPSCRing`, `SoundMailbox`, the file and mic tap sources (Darwin) |
| `NardukSonify`        | `NardukMusicCore`                        | the stream sonifier lifted from DataBeatsKit (A3)                                                                          |
| `NardukSoundVisuals`  | `NardukSoundAnalysis`, `NardukMusicCore` | `SoundVisualState`, `SoundVisualInput`, palette, render budget, visualizers, gallery                                       |

Existing products keep their public API. The dependency edge is `NardukMusicDSP`
-> `NardukSoundAnalysis`, added by A2 when the types move:

- **Analysis owns** `SoundFrame`, `SpectrumAnalyzer`, the decibel helper
  (`DSP.decibels` today, `DSPPrimitives.swift:55`) and `SPSCRing`.
  `NardukMusicDSP` re-exports them by `public typealias`, so existing imports
  keep compiling. Both moved files currently `import NardukMusicCore` and use
  nothing from it (verified: `SpectrumAnalyzer.swift` and `SPSCRing.swift` name
  no Core type), so the import is dropped and Analysis stays dependency-free.
  The analyzer calls the decibel helper, which is why the helper moves too.
- **The engine-to-`SoundFrame` adapter lives in `NardukMusicEngine`**, never in
  Analysis: it needs `DropSynthCore.copyRecentSamples` and `takeHits`, which are
  DSP and Engine, and Analysis cannot depend on either (that would be a cycle).
- `VisualizerFrame` stays as a deprecated adapter until A6.
- **Linux.** Core, DSP, Render, Analysis and Sonify build on the Linux gate.
  `NardukSoundVisuals` and the AVAudioEngine tap source sit behind
  `#if canImport(Darwin)` (or `canImport(SwiftUI)` / `canImport(AVFoundation)`)
  in the root manifest and inside the target. The Linux-buildable core of
  Visuals (`SoundVisualState`, palette math, the budget function) is plain Swift
  and is compiled on Linux where its manifest placement allows.

Platforms are macOS 15 and iOS 18 from the first commit (the root manifest
already declares them).

### Where each type lives

`SoundFrame` has no dependencies, so it is in Analysis. `MusicContext` names
`Instrument` and `SongSection`, which are in Core, and Analysis must not depend
on Core, so `MusicContext` is in **NardukMusicCore**. The pair is joined only in
Visuals (`SoundVisualInput`). The engine adapter (NardukMusicEngine) depends on
both and publishes both.

## 2. The types

### SoundFrame (NardukSoundAnalysis)

What any sound is doing at about 60 Hz. Every visualizer must work from this
alone.

```swift
public struct SoundFrame: Sendable, Hashable {
    /// Strictly increasing per source, starting at 1. 0 means "no frame yet". The only "is this new?" test.
    public var sequence: UInt64
    /// Seconds on the source's own timeline: samples rendered / sample rate for the engine and offline renders,
    /// host time for a microphone or tap. Used for staleness and replay, never for animation (see section 4).
    public var time: Double
    /// 64 log-spaced bands, 20 Hz to 16 kHz, 0 ... 1 (the SpectrumAnalyzer layout today).
    public var spectrum: [Float]
    /// The latest 512 mono output samples, -1 ... 1.
    public var waveform: [Float]
    /// Master bus peak and RMS in dBFS; -120 is silence.
    public var peakDB: Float
    public var rmsDB: Float
    public init(sequence: UInt64 = 0, time: Double = 0, spectrum: [Float] = ..., waveform: [Float] = ...,
                peakDB: Float = -120, rmsDB: Float = -120)
}
```

The initializer is public with defaults because apps build synthetic frames
(Wirewatcher's `DemoDropModel` and `DropOfflineModel` both do today). Band count
and sample count are named constants (`SoundFrame.bandCount`,
`SoundFrame.sampleCount`), never magic numbers in a visualizer.

Onsets, beat, chroma and pitch are not here. They are added as optional fields
when a visualizer needs one (A9).

### MusicContext (NardukMusicCore)

What music knows about itself, when the source is music. Visualizers use it when
present and degrade without it. Only what the engine can emit today.

```swift
public struct MusicContext: Sendable, Hashable {
    /// Per-instrument hit counters, monotonic, wrapping. Consumers diff against the last value they saw.
    public var hitCounts: HitCounters
    /// Conductor step, 16ths.
    public var step: Int
    public var section: SongSection
    /// Conductor energy 0 ... 1.
    public var energy: Float
    /// Wobble LFO phase 0 ... 1 and filter cutoff 0 ... 1.
    public var wobblePhase: Float
    public var wobbleCutoff: Float

    // Beat clock: what a consumer needs to interpolate `step` between frames.
    public var isRunning: Bool
    /// Seconds per 16th (60 / bpm / 4).
    public var secondsPerStep: Double
    public var stepsPerBar: Int
    public var stepsPerPhrase: Int
    /// Progress through the current phrase, 0 ... 1 (the tunnel's build speed reads it).
    public var phraseProgress: Float

    // Conductor state the Data Beats timeline and stage draw.
    public var buildThreshold: Float
    public var dropThreshold: Float
    public var dropQueued: Bool
}

/// 14 instruments fit 16 lanes: a fixed-size value, no allocation, indexed by `Instrument.index`.
public struct HitCounters: Sendable, Hashable { var lanes: SIMD16<UInt32> /* subscript(Instrument) -> UInt32 */ }
```

Everything past the plan's list is something a visualizer in one of the two apps
reads today (section 8). The beat clock fields are `settings.secondsPerStep`,
`settings.stepsPerBar`, `settings.stepsPerPhrase`, `snapshot.phraseProgress` and
`model.isRunning` in Wirewatcher's `DropVisualState.update`; the thresholds are
`snapshot.buildThreshold` and `dropThreshold` in Data Beats'
`EnergyTimelineView` (`LiveAudioViews.swift:164-165`) and `dropQueued` is the
stage's "armed" readout (`StageView.swift:116`). All exist on `SongSettings` and
`ConductorSnapshot` today.

**Hits are counters, not a per-publish set.** `DropSynthCore.takeHits()`
(`DropSynthCore.swift:478`) clears a `Set<Instrument>` on every 60 Hz publish. A
consumer that skips frames (the iOS thermal cap is 30 fps) skips their hits too,
and `sequence` can tell a frame is new but cannot recover edges it never saw. A
consumer keeps the counters it last saw and diffs: `delta = now &- last`, per
instrument, with wrapping subtraction. That keeps edges _and_ their multiplicity
(two kicks inside one 33 ms poll are 2), needs no merge in the mailbox, and
builds without allocating (a `Set` allocates when constructed). An earlier draft
of this document used an `OptionSet` OR-ed in the mailbox; that keeps edges but
loses multiplicity and needs a producer-supplied merge, so it was replaced.

When the source is not music, `music` is `nil`. Visualizers that want a wobble,
a section or a beat fall back as in section 3.

## 3. SoundVisualState (NardukSoundVisuals)

One main-actor class that turns the latest frame into drawable state, so every
visualizer on screen draws from the same smoothed numbers. Source of truth is
Wirewatcher's `DropVisualState` (504 lines); Data Beats' `SpectrumCaps`,
`PadState`, `MeterState` and the state half of `StageFX` fold in.

```swift
public struct SoundVisualInput: Sendable {
    public var frame: SoundFrame
    public var music: MusicContext?
}

public struct SoundVisualOptions: Sendable, Equatable {
    /// Calm (Reduce Motion): gates flash, shake, chroma, glitch and the particle spawners; slower smoothing.
    public var calm = false
    /// A generic 0 ... 1 external drive: Wirewatcher's smoothed traffic intensity, an iPad's motion, a data rate.
    /// It sets how wild the stage is (travel, saturation, shake, particle counts). nil means "as wild as the
    /// music's energy" (or, with no MusicContext, as loud as the signal).
    public var drive: Float?
}

@MainActor public final class SoundVisualState {
    public init(configuration: SoundVisualConfiguration = .init(), seed: UInt64 = 0x9E37_79B9_7F4A_7C15)
    public func update(_ input: SoundVisualInput, now: Double, options: SoundVisualOptions)
    // read-only outputs: see below
}
```

`SoundVisualConfiguration` holds the constants the two apps disagree on, so
porting does not change either look: spectrum attack and release, the peak-cap
hold and fall (Wirewatcher 0.4 s and 0.55/s; Data Beats 0.45 s and 0.9/s), pad
decay (Data Beats `exp(-4.5 dt)`), meter windows (Data Beats -60 ... 0 dB;
Wirewatcher's `level` -48 ... 0 dB) and the particle capacity. Defaults are
Wirewatcher's.

### Outputs

| Group     | Members                                                                                                            | From                                      |
| --------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| Spectrum  | `spectrum[64]` smoothed, `peaks[64]` with hold                                                                     | `DropVisualState`, `SpectrumCaps`         |
| Waveform  | `waveform[512]`, a ring of the last 10 (`history`, `historyHead`, `historyCount`)                                  | `DropVisualState`                         |
| Meters    | `peak`, `rms`, `peakHold`, `level` (0 ... 1)                                                                       | `MeterState`, `DropVisualState.level`     |
| Pads      | `padBrightness[Instrument]`, a fixed array indexed by instrument, not a dictionary                                 | `PadState`                                |
| Envelopes | `kick`, `snare`, `hat`, `glitch`, `laser`, `impact`, `flash`, `shake` (+ `shakeOffset`), `chroma`                  | `DropVisualState`                         |
| Music     | `wobblePhase`, `wobbleCutoff`, `energy`, `section`, `phraseProgress`, `dropAmount`, `travel`, `energyHistory[128]` | `DropVisualState`                         |
| Clock     | `time`, `stepPosition`, `beats`, `beatPhase`, `barPhase`, `beatPulse`, `fps`                                       | `DropVisualState`                         |
| Mood      | `wild`, `calm`, `palette` (the blended, saturated palette)                                                         | `DropVisualState`                         |
| Particles | a fixed pool of 320 (`ring`, `spark`, `streak`, `block`), normalized coordinates                                   | `DropVisualState`, `StageFX`              |
| Silence   | `isSilent` (true when RMS is below -100 dB and no band exceeds 0.002)                                              | replaces Data Beats' per-view `live` test |

Without a `MusicContext`, `energy` falls back to `level`, the section is
`.intro`, wobble values are 0, hits come from the low-band onset detector
`DropVisualState` already has for sparse engines, and the clock runs on wall
time at the last known tempo (`beatPulse` is 0).

### Rules

1. **Idempotent per display frame.** `update` returns immediately if `now` is
   within 2 ms of the last update, so the stage, the button and the meters can
   all call it. `dt` is clamped to 0.1 s.
2. **Never allocates.** Every buffer, the particle pool and the history rings
   are allocated in `init`. Nothing in `update` builds an array, string, closure
   or `Set`. Enforced by a test (section 7).
3. **`now` is passed in**, never read from a clock inside the state. Live views
   pass `CACurrentMediaTime()`; the offline renderer passes its own tick time,
   which is how Wirewatcher renders video today.
4. **Stale gap.** An update more than 0.5 s after the last one (the view was
   hidden) skips the backlog instead of replaying it.
5. **Deterministic.** The only randomness is a seeded xorshift, so a fixed frame
   sequence yields a fixed state, which is what makes golden images possible.
6. **No app concepts.** `drive` is a number, never a traffic type. Traffic
   sprites, logo pulses, `pendingPulses` and `trafficIntensity` are
   Wirewatcher's and move to a Wirewatcher-owned `TrafficLogoState` that reads
   the same clock (`stepPosition`, `beats`). The Data Beats data comet and
   `PlayheadClock` stay in the app.
7. **Calm and photosensitivity.** Wirewatcher gates flash, shake, chroma, glitch
   and the particle spawners on `calm` at about fifteen sites in
   `DropVisualState`; that becomes one rule of the state, not a per-visualizer
   habit. In every mode the full-stage `flash` fires at most three times a
   second (today: at most once per 0.4 s, and only on a drop transition) and its
   envelope decays in under 0.2 s; in calm mode it is 0, as are shake and
   chroma. Apps set `calm` from the system Reduce Motion setting
   (`accessibilityReduceMotion`) and may also offer their own switch. A new
   visualizer that adds a flashing effect must route it through the state's
   `flash`, which is the only place the rate limit lives.

## 4. Polling, ordering and thread rules

- **Poll, never observe.** Frames are read on the visualizer's own
  `TimelineView` or `MTKView` clock. Observing a frame property re-runs SwiftUI
  bodies at 60 Hz (Wirewatcher #65). `DropEngine.latestFrame` is already
  `@ObservationIgnored`.
- **`sequence` replaces `FrameSignature`.** Wirewatcher builds a hash of six
  fields per update to ask "is this a new frame?", and Data Beats' `StageFX`
  compares whole frames (`frame != lastHitFrame`). Both become
  `sequence != last`.
- **Hits are counters.** See section 2: the producer increments a per-instrument
  counter on every hit and the consumer diffs against the last value it saw, so
  skipping frames loses nothing. Data Beats' pads and `StageFX` read
  `latestFrame.hits` directly today and have the loss.
- **`SoundMailbox<Value>`** (NardukSoundAnalysis) is a plain latest-value box
  for handing a frame from the analysis side to the main actor: `publish`
  overwrites, `take()` returns the value once. Nothing is merged, because
  nothing can be lost by overwriting (counters survive, and `peakDB` is the
  level at that frame).
- **Analysis runs off the audio thread**, fed through the lock-free `SPSCRing`
  (moving to Analysis with the analyzer; the audio thread pushes samples, the
  analysis side pops them). The mailbox may take a lock because neither of its
  sides is the render thread.
- **Frames may allocate** (two small arrays at 60 Hz, off the render thread);
  `SoundVisualState.update` may not.
- **Offline.** An offline renderer produces frames on its own timeline (`time`
  from samples rendered) and passes its own `now`. The same visualizers draw a
  render and a live session.

## 5. Render budget

One place decides how fast the visuals animate, taken from Wirewatcher's
`DropFrameRate` (written after the 2026-10-06 WindowServer watchdog panic on a
hot 120 Hz display):

```swift
public enum SoundRenderBudget {
    public static let normal = 60
    public static let reduced = 30
    /// 0 means paused: hold the last frame, schedule nothing.
    public static func framesPerSecond(isVisible: Bool, thermal: ProcessInfo.ThermalState,
                                       lowPowerMode: Bool) -> Int
    public static func schedule(_ fps: Int, cap: Int = normal) -> AnimationTimelineSchedule
}
extension EnvironmentValues { @Entry public var soundFramesPerSecond: Int }
```

- 60 fps is the cap on every display, 120 Hz included. The visuals are soft
  glows and beat-locked motion.
- Not visible means 0: minimized, fully occluded or on another Space on macOS;
  scene not `.active` on iOS.
- `.serious` thermal state means 30, `.critical` means 0. On iOS, Low Power Mode
  also means 30.
- The environment value is set by the host view; views take their rate from it
  and never from the display.
- Visibility reporting is platform glue behind `#if canImport(AppKit)` /
  `#if canImport(UIKit)` (Wirewatcher's `WindowVisibilityReader` is AppKit only;
  the iOS twin reads `scenePhase`). The Metal tunnel gets a
  `UIViewRepresentable` twin and keeps `TunnelDrawableSizer` (cap 2560 x 1440
  pixels, reallocate only after the size holds still for 150 ms).

## 6. Palette

Visualizers take a palette and never name a color. Apps supply theirs.

```swift
public struct SoundPalette: Equatable, Sendable {
    public var c0: SIMD3<Float>, c1: SIMD3<Float>, c2: SIMD3<Float>   // the three neon colors, linear 0 ... 1
    public func mixed(with: SoundPalette, _ t: Float) -> SoundPalette
    public func saturated(_ amount: Float) -> SoundPalette
    public func sample(_ t: Float) -> SIMD3<Float>                    // cyclic c0 -> c1 -> c2 -> c0
}
/// What picks the palette: a song section, or a scalar for sources with no music.
public enum SoundPaletteDriver: Sendable, Equatable {
    case section(SongSection)
    /// 0 ... 1, from the signal: the state derives it from the smoothed spectral centroid for a mic or a file.
    case scalar(Float)
}
public protocol SoundPaletteProvider: Sendable {
    func palette(for driver: SoundPaletteDriver) -> SoundPalette
}
```

Blend, saturation and cyclic sampling are Wirewatcher's `DropPalette`, lifted
unchanged. The section-to-palette table is the app's: Wirewatcher's
`SongSection.palette` and Data Beats' `Neon.section` (one hue per section)
become two providers. Data Beats gives `c1` its section hue and picks `c0` and
`c2` as neighbors, so its Canvas code reads `palette.c1` where it read
`Neon.section(...)`. Chrome (backgrounds, grid, text) stays in the app; only
series colors come from the palette. The `.scalar` driver is for microphone and
file sources, which have no section: a provider maps 0 ... 1 to a palette (a hue
sweep along `c0` -> `c1` -> `c2` with `sample(_:)` is the obvious default).
`SoundVisualState` chooses the driver: `.section` when a `MusicContext` is
present, else `.scalar`. The gallery ships a default provider.

## 7. Proof

Written into the package, not folklore (the precedents are in
`NardukMusicDSPTests` and `NardukMusicRenderTests`):

- **Golden images.** A fixed `SoundFrame` + `MusicContext` sequence, a fixed
  seed and a fixed `now` series render each visualizer to an image compared
  against a committed golden (per platform, as the render goldens are).
- **No-allocation tests** on `SoundVisualState.update` and on each visualizer's
  draw-state path, in a release build, following `RenderThreadAllocationTests`.
- **Idempotence test:** two `update` calls inside 2 ms leave every output
  unchanged.
- **Hit counter tests:** a consumer polling every third frame sees the same
  total hits per instrument as one polling every frame, including two hits
  between polls; counters wrap without a spurious delta.
- **Flash rate test:** under any frame sequence, `flash` rises at most three
  times in one second, and never in calm mode.
- **Analyzer tests** on synthetic signals (A2): a sine lands in the right band,
  silence reads -120 dB.

## 8. Audit

Sources read (origin/main, 2026-10-06): data-beats `902d4e6`,
`App/Sources/Visuals/**`; wirewatcher `4c7d38f`, `App/Sources/Views/Drop/**`.
The bodies of the Data Beats data charts (`AnalysisCharts`, `DataScoreView`,
`LiveScoreView`, `MatrixViews`, `PhaseViews`) take no `VisualizerFrame` or
engine state; they are data views and stay in the app.

### Overlap

| Concern       | Data Beats                               | Wirewatcher                         | Shared form                               |
| ------------- | ---------------------------------------- | ----------------------------------- | ----------------------------------------- |
| Spectrum bars | `SpectrumBarsView`, `SpectrumCaps`       | `DropRenderers.mirror`, `peaks`     | `spectrum`, `peaks`                       |
| Waveform      | `OscilloscopeView`, Stage waveform ring  | `phosphor`, `history`               | `waveform`, `history`                     |
| Wobble        | `WobbleMeterView` (dial: phase + cutoff) | tunnel uniforms, `halo`             | `wobblePhase`, `wobbleCutoff`             |
| Meters        | `MeterState` (-60 ... 0 dB)              | `level` (-48 ... 0 dB)              | `peak`, `rms`, `level`                    |
| Hit flash     | `PadState`, `StageFX` particles          | kick/snare/hat envelopes, particles | `padBrightness`, envelopes, particle pool |
| Section color | `Neon.section`                           | `SongSection.palette`               | `SoundPaletteProvider`                    |
| Frame budget  | `TimelineView(.animation)` uncapped      | `DropFrameRate`                     | `SoundRenderBudget`                       |
| Stage orb     | `StageView` (spectrum ring, core, comet) | `DropStage` (+ HUD, logos)          | visualizer plus app overlay               |

Data Beats redraws on `TimelineView(.animation)` at the display rate with no cap
and no visibility pause; moving it onto `SoundRenderBudget` is a behavior change
it gains for free (A7).

### Fields each visualizer needs, against the contract

| Visualizer                         | Reads                                                                             | In the contract                   |
| ---------------------------------- | --------------------------------------------------------------------------------- | --------------------------------- |
| Data Beats spectrum, scope         | spectrum, waveform, section                                                       | yes                               |
| Data Beats wobble meter            | wobblePhase, wobbleCutoff, peakDB, rmsDB, section                                 | yes                               |
| Data Beats pads                    | hits per frame                                                                    | yes (hit counters, G4)            |
| Data Beats stage orb               | spectrum, waveform, hits, section, energy; data comet and playhead                | audio side yes; comet is app-side |
| Wirewatcher mirror, halo, phosphor | spectrum, peaks, history, palette, kick, flash, chroma, shake, travel, beat clock | yes                               |
| Wirewatcher Metal tunnel           | the above plus snare, hat, impact, glitch, wild, dropAmount, barPhase, wobble     | yes                               |

### Gaps found, and what the contract does about each

| #   | Gap                                                                                                                                 | Resolution                                                                                                                                                                                              |
| --- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G1  | The beat clock needs the tempo (`settings.secondsPerStep`); the plan's `MusicContext` has none                                      | added `secondsPerStep`, `stepsPerBar`, `stepsPerPhrase`                                                                                                                                                 |
| G2  | The tunnel's build speed needs `phraseProgress`, computed from `settings.stepsPerPhrase`                                            | added `phraseProgress`                                                                                                                                                                                  |
| G3  | `isRunning` gates the clock and `beatPulse`                                                                                         | `MusicContext.isRunning`                                                                                                                                                                                |
| G4  | Hits are lost when a frame is overwritten or skipped (engine publish, a 30 fps consumer, Data Beats pads)                           | per-instrument hit counters, sections 2 and 4                                                                                                                                                           |
| G5  | `calm` (reduced motion) is an app switch, with a photosensitivity rule                                                              | `SoundVisualOptions.calm`, state rule 7                                                                                                                                                                 |
| G6  | `wild` mixes live traffic into the stage; a motion-driven iPad needs the same slot                                                  | `SoundVisualOptions.drive`, a plain `Float`; traffic itself stays in Wirewatcher                                                                                                                        |
| G7  | `DropVisualState` is also the logo-sprite scheduler                                                                                 | split out to a Wirewatcher `TrafficLogoState` (A4 lifts the rest)                                                                                                                                       |
| G8  | Wirewatcher hard-codes 4 steps per beat and 16 per bar                                                                              | `MusicContext.stepsPerBar` (16ths stay 4 per beat)                                                                                                                                                      |
| G9  | Two peak-cap, pad and meter constant sets                                                                                           | `SoundVisualConfiguration`                                                                                                                                                                              |
| G10 | The stage fades in only when `live` (spectrum max > 0.002)                                                                          | `SoundVisualState.isSilent`                                                                                                                                                                             |
| G11 | No iOS visibility report                                                                                                            | `SoundRenderBudget` platform glue, section 5                                                                                                                                                            |
| G12 | Data Beats' `EnergyTimelineView` draws the build and drop thresholds and a per-step section history; `StageView` shows `dropQueued` | **closed.** `buildThreshold`, `dropThreshold`, `dropQueued` added to `MusicContext`; the state keeps a section ring beside `energyHistory`                                                              |
| G13 | `SpectrumAnalyzer` already smooths (attack 0.65, release 0.12 per frame) and `DropVisualState` smooths again (34 and 8 per second)  | open, for A2 and A4: either the analyzer emits raw bands and the state owns smoothing, or the state's smoothing is configurable down to none. Default until decided: configurable, Wirewatcher's values |

HUD text (section title, bar.beat, BPM, wobble rate, legend, track) is not
visualizer input. Apps keep reading `ConductorSnapshot` for it.

Everything either app draws from the engine is covered once G1 to G12 are
applied. G13 is the only open item and does not block A2, A3 or A4.

## 9. Which lane does what

| Phase       | Reads this document for                                                                                               |
| ----------- | --------------------------------------------------------------------------------------------------------------------- |
| A2 analysis | `SoundFrame`, the analyzer, decibel and ring moves (DSP re-exports by typealias), `SoundMailbox`, the tap source, G13 |
| A3 sonify   | the `NardukSonify` boundary: it emits `MusicSignal`s only and knows nothing of frames                                 |
| A4 gallery  | `SoundVisualState`, `SoundVisualInput`/`Options`, palette, budget, G7                                                 |
| A5 port     | the overlap table, `SoundVisualConfiguration` (so the ports look unchanged)                                           |
| A6 music    | `MusicContext`, `HitCounters`, the Engine adapter, the `VisualizerFrame` adapter                                      |
| A7, A8      | what each app deletes and what it keeps (G7, G12)                                                                     |

## 10. Source compatibility

Adding a case to `Genre`, `Instrument` or `SongSection` is **source-breaking for
every exhaustive `switch` over it** in the two apps. A Track B lane that adds a
case must list the app edits it forces in its PR and on the board. Known
exhaustive switches at data-beats `902d4e6` and wirewatcher `4c7d38f`:

| Enum          | Data Beats                                | Wirewatcher                                   |
| ------------- | ----------------------------------------- | --------------------------------------------- |
| `SongSection` | `Neon.section`, `VisualKit.swift:22-30`   | `SongSection.palette`, `DropPalette.swift:80` |
| `Genre`       | `genreName`, `Views/Panels.swift:294-296` | the `title` switch, `DropPanel.swift:251-253` |

`Instrument` is also a fixed lane count in `HitCounters` (16 lanes, 14 used):
adding a case past 16 changes that type, so A6 asserts the count at compile
time. `SoundPaletteProvider` takes a `SoundPaletteDriver`, so a new section
never forces an edit inside the library, only in the app's provider.
