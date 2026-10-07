# ConductorDriver: one live pump (narduk-sound#5)

Four apps copy a conductor-to-synth pump with a "the step went backwards, so restart the song" hack, and only
`OfflineRenderer` follows `DropConductor.lastSwitch`. `ConductorDriver` (NardukMusicEngine) replaces them.

## API

- `ConductorDriver(settings:source:)` plays a `DropConductor`; `ConductorDriver(part:)` plays a fixed `SongPart`
  (`SongPart.demo` is `DemoPattern`; SoundGallery's guitar part fits the same shape).
- Controls, from any thread: `next()` (skip: a different genre from the seed's own stream, at the next bar line),
  `setGenre`, `setTempo` (next bar line), `queueDrop`, `setThresholds`, `ingest(_ signal:)`, `withConductor`.
- Reads, from any thread: `status` (genre, bpm, pending genre, section, snapshot, track, written step) and
  `status(heardAt:)`, which reports the genre and tempo the listener hears at an audible step.
- Transport stays on `DropEngine`: `engine.play(driver)` attaches it and starts or resumes, `pause()`, `resume()`,
  `stop()`. `driver.next()` is skip. `noteProvider` stays for apps not yet migrated; a driver wins when both are set.

## Cursor and look-ahead

The driver owns the cursor (the last song step written) and writes every step up to the core's
`renderedStepPosition` plus a look-ahead of `max(0.1 s, two IO buffers)`, so a large screen-off buffer never starves
it. Song steps never go backwards. Pause and resume keep the same `DropSynthCore`, so the cursor simply carries on.
When `start()` builds a new core (after `stop()`, or a graph rebuild before narduk-sound#6 keeps the core), the driver
keeps writing: it maps core step 0 to the next song bar line (`origin`), and the engine adds `origin` to
`currentStep`. Nothing restarts the song except a new driver.

## Tempo, genre and key

After each write the driver compares `conductor.lastSwitch` with the one it last applied. A new switch calls
`core.setTempo` at write time: the switch step is a bar line inside the look-ahead, so the render position is still
in the bar before it, and `StepClock` lands the change exactly on the switch bar. (`OfflineRenderer` applies it once
the step is audible, which is one bar late: the new genre's first bar plays at the old tempo. Its test records this.)
Genre and key travel in the notes and `snapshot.track`; `status(heardAt:)` flips genre and bpm at the switch step,
and the engine echoes them into `settings` without re-sending the tempo, so a stale echo never retargets a
pending change.

## Energy and signals

A `ConductorSource` is a value the driver owns, called on the pump thread before each write with the song time the
write reaches (seconds of music written, summed step by step, so a tempo change never runs it backwards):
`feed(_ conductor: inout DropConductor, time:)`, plus an optional `decorate(_ notes:conductor:)` after it (Data
Beats' lead composer). `EnergyCurve(cycleSeconds:dropAt:level:)` is the scripted kind: SoundGallery's 32 s loop and
Forever Loop's 150 s swell are two instances. Data that arrives on its own clock (Data Beats, Wirewatcher) calls
`driver.ingest(signal)` from any thread; queued signals are fed before the next write, in arrival order.

## Threading

The driver's state sits behind a `Mutex`. The render block signals a semaphore after each buffer (no allocation, no
lock); a dedicated `.userInteractive` pump thread waits on it (with a 25 ms timeout as a backstop) and writes. So the
pump follows the audio clock and keeps writing with the screen off or the main thread busy; the main-actor timer is
left with analysis and publishing only. Every push into the synth's single-producer ring (the driver's notes,
`cut`, the vocal riser) goes through one producer lock, which also guards the note tracker. Offline rendering
(`renderOffline`, the tests) pumps synchronously on the caller, so a seed and a buffer schedule give the same notes
and samples every run.

## DropEngineDemo

`playDemo()` becomes `play(.demo())`: the same eight-bar `DemoPattern` loop, through the driver, so it neither
rewinds nor rides the main run loop. `DropEngineDemo` stays one release as a deprecated `noteProvider` shim.
