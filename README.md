# NardukMusic

A generative music engine: a conductor that writes a song from whatever your app
is doing, and a synth that plays it. Extracted from
[Wirewatcher](https://github.com/narduk-enterprises/wirewatcher) at `84bbb7e`
(narduk-libs#1520), where it turns network traffic into a dubstep set; Buildbeat
turns a build into one. Your app sends **signals** (a level, some flow, short
cues), and the conductor builds, drops and changes tracks to match.

| Product               | Platforms         | What it is                                                                                                                                                                                                                        |
| --------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NardukMusicCore`     | macOS, iOS, Linux | `DropConductor`, the song model and the `MusicSignal` input. Pure and clock-free.                                                                                                                                                 |
| `NardukMusicDSP`      | macOS, iOS, Linux | `DropSynthCore`, the instruments and the limiter (`SpectrumAnalyzer` and `SPSCRing` forward to NardukSoundAnalysis).                                                                                                              |
| `NardukSoundAnalysis` | macOS, iOS, Linux | Any audio to a `SoundFrame` (spectrum, waveform, loudness): `SoundAnalyzer`, `SPSCRing`, `SampleRing`, ring and recent-sample sources, and (Apple only) `AudioTapSource` for a mic, mixer or file through `AVAudioEngine`. No UI. |
| `NardukSonify`        | macOS, iOS, Linux | `StreamSonifier`: a stream of numbers to the `MusicSignal`s the conductor plays, online and in bounded memory.                                                                                                                    |
| `NardukSoundVisuals`  | macOS, iOS, Linux | `SoundVisualState`, the render budget and the palette contract: what a visualizer reads each frame, from a `SoundFrame` and an optional `MusicContext`. No drawing.                                                               |
| `NardukMusicRender`   | macOS, iOS, Linux | `OfflineRenderer`, JSON scenarios and WAV / M4A writing.                                                                                                                                                                          |
| `NardukMusicEngine`   | macOS, iOS        | `DropEngine`: the real-time AVAudioEngine host and the recorder. It publishes `latestSound` (a `SoundFrame`) and `latestMusic` (a `MusicContext`); `makeSoundSource()` adapts its output for analysis.                            |
| `narduk-music`        | macOS, Linux      | A CLI that renders a scenario to a WAV.                                                                                                                                                                                           |

```swift
.package(url: "https://github.com/narduk-enterprises/narduk-libs", exact: "0.4.0")
```

Then add `.product(name: "NardukMusicEngine", package: "narduk-libs")` (or
`NardukMusicCore`, etc.) to the target. The repository is public, so resolving
it needs no credential.

## The gallery app

`Apps/SoundGallery` is a SwiftUI app for macOS, iPad and iPhone that plays the
demo song, the microphone or an audio file through `NardukSoundAnalysis` into
four Canvas visualizers side by side (`xcodegen generate`, then build the
`SoundGallery` scheme; `-autoplay demo|microphone` starts a source at launch).
It is unsigned and local only; CI builds it for macOS and the iOS simulator.

## Reading the engine

`DropEngine` publishes two values about 60 times a second, and a visualizer
polls them on its own `TimelineView` or `MTKView` clock (never observe them:
that re-runs SwiftUI bodies at 60 Hz).

- `latestSound`: a `SoundFrame`, what any sound is doing (spectrum, waveform,
  peak and RMS). `sequence != last` is the "is this new?" test.
- `latestMusic`: a `MusicContext`, what the music knows about itself: the step,
  section, the beat clock, the wobble, and per-instrument `HitCounters`. Keep
  the counters you last saw and take `delta(since:)`: a consumer that skips
  frames (the iOS thermal cap) loses no hit, and two hits in one poll count as
  two. The render thread bumps the counters without allocating.
- Energy, the build and drop thresholds and `dropQueued` are the conductor's:
  copy `DropConductor`'s snapshot into `engine.conductor` and they ride along.

`VisualizerFrame` and `DropEngine.latestFrame` still build, with a deprecation
warning, for one minor version. They are an adapter over the two values above.

## Make your own source

An adapter turns your app's events into `MusicSignal`s. This one plays a build.
CPU heat is the level, so the conductor builds as the machine works and drops at
the peak. Each tool that starts is a cue: one hit placed on the beat and named
in the legend.

```swift
import NardukMusicCore
import NardukMusicEngine

@MainActor final class BuildMusic {
    let engine = DropEngine(settings: SongSettings(genre: .dubstep, seed: SongSettings.sessionSeed()))
    private var conductor = DropConductor(settings: SongSettings())

    init() throws {
        conductor = DropConductor(settings: engine.settings)
        conductor.setThresholds(build: 0.45, drop: 0.32)  // heat rarely reaches the default 0.55
        engine.noteProvider = { [unowned self] through in conductor.advance(throughStep: through) }
        try engine.start()
    }

    /// Call from your build events, on the main actor.
    func heat(_ cpu: Double) {
        conductor.ingest(MusicSignal(level: cpu, levelLabel: "CPU \(Int(cpu * 100))%"))
    }

    func toolStarted(_ name: String, kind: String) {
        let cue: MusicCue = switch kind {
        case "compiler": .spark(name)  // a laser on a chord tone, the same note for the same name
        case "linker": .stutter(name)
        default: .voice(name)
        }
        conductor.ingest(MusicSignal(cues: [cue], pan: kind == "linker" ? 0.6 : -0.3))
    }

    func buildFinished() {
        conductor.ingest(MusicSignal(cues: [.impact("build done"), .tapeStop("build done")]))
        conductor.queueDrop()
    }
}
```

`conductor.snapshot` carries the section, the energy, the track and a legend of
what each sound means ("laser ← swiftc"), for your UI. The other knobs:

- **`level`** (0 … 1) is sticky: it holds until a later signal sets a new one,
  or `releaseLevel()` hands the energy back to the flow.
- **`flow`** is for sources that measure throughput, like bytes, starts and
  faults per named source. Without a level, the energy follows it on a log scale
  against the busiest moment seen. It also feeds the character classifier, and
  the busiest source picks the bass variant.
- **`character`** pins `idle`, `busy`, `steady`, `surge` or `chaos`. Without it,
  the flow is classified. The character picks and steers the next track.
- **Cue gestures**:
  - `tick`: hi-hat ticks, a trap roll in bursts
  - `spark`: laser
  - `zap`: laser at a `height`
  - `sparkle`: calm sections only
  - `voice`: formant vocal
  - `ghost`: ghost snare
  - `stutter`: glitch
  - `scratch`
  - `swell`: riser
  - `impact`
  - `tapeStop`

Cues are quantized to the grid, so a burst becomes a pattern.

## Render offline and from the command line

`OfflineRenderer` runs the conductor and the synth on a virtual 60 Hz clock,
tick for tick like the live engine, with no audio device. The same seed and
signals give the same samples, bit for bit. A scenario is JSON: listed `signals`
and/or `segments` that repeat a signal with a ramped level and rotating cues,
plus timed `actions`. See
[scenarios/build-session.json](scenarios/build-session.json).

```sh
swift run -c release narduk-music render --scenario packages/modules/narduk-music/swift/scenarios/build-session.json \
  --out /tmp/build-session.wav [--seconds 60] [--genre house] [--seed 7] [--bpm 150] [--json]
```

Exit codes: 0 rendered, 64 bad usage, 65 bad scenario, 74 write failed. `.m4a`
output needs AVFoundation, so macOS only.

### Guitars

Five more `Instrument`s are plucked-string voices (Karplus-Strong with a tuned
loop filter and a per-kind body, cabinet or bass stage): `acousticGuitar`,
`electricGuitar`, `bassGuitar` and the six-string `strum` and `electricStrum`.
The bass guitar plays on the bass bus (ducked by the kick); the rest play on the
FX bus. A strum expands into six staggered string events (12 ms down, 8 ms up);
its `voice % 6` picks the chord (major, minor, dominant 7, minor 7, power, sus2)
and `formant >= 0.5` strums up.

A scenario names them with a `notes` array: `time` (seconds), `pitch` (MIDI),
optional `length`, `velocity`, `pan`, `drive`, `chord`, `direction` and an
`instrument` name. Times quantize to the nearest half step. `"conductor": false`
silences the generated song so the notes play alone. See
[scenarios/instruments](scenarios/instruments) and the mixed
[scenarios/guitar-demo.json](scenarios/guitar-demo.json).

## Sonify a stream (NardukSonify)

`NardukSonify` turns a stream of numbers into the `MusicSignal`s the conductor
plays, online, with no knowledge of what the numbers are. It depends on
NardukMusicCore only and builds on every platform.

```text
values in schema order -> StreamSonifier.ingest -> StreamFrame -> signal(frames, time:) -> MusicSignal
```

- `StreamSchema` fixes the columns up front, so a sample is just its values in
  that order (an unsafe buffer or an array); a value that is not finite means
  "nothing this time". No dictionary, no sorting per sample.
- `OnlineSeries` analyses one column causally and in bounded memory: time-based
  EWMAs, a robust range from the 2nd/98th percentiles of a 60 s window
  (quickselect in preallocated storage), peaks confirmed a quarter second late,
  anomalies at |z| > 3.5.
- `StreamSonifier` rate-limits events as they happen (2 a second, bursts of 4),
  queues a drop on a new high, and raises open `StreamEventKind`s. A
  `StreamColumnRanker` decides which column leads; the default ranks all alike.
- `ingest` allocates nothing while no event fires (`StreamNoAllocTests`, release
  builds); an event builds its label strings, and `signal(_:time:)` builds a
  `MusicSignal`, so call it once per tick.

## Guarantees and their tests

- **Golden render.** `GoldenRenderTests` renders the 30 s scenario and compares
  an FNV-1a fingerprint of every sample with a per-platform golden: libm can
  differ in the last bit between platforms. A different seed must write a
  different song. When the music changes on purpose, listen to the CLI's output
  and update the golden from the failure message.
- **Conductor determinism.** The same settings and signals produce the same
  notes (`DropConductorTests`, `MusicSignalTests`).
- **No allocation on the render thread.** `RenderThreadAllocationTests` hooks
  libmalloc's `malloc_logger` and renders every instrument through a tempo
  change. It runs under `swift test -c release`, because a debug build boxes
  unspecialized generics. The render path also takes no lock and uses no Swift
  concurrency. Notes reach it through a lock-free single-producer ring.

`scripts/swift-quality.py` runs the lint, the tests (debug, then release for the
allocation check), the CLI and a version-tag consumer.
`.github/workflows/narduk-music-swift.yml` runs it on Linux and macOS, plus a
consumer build on Xcode 26.0.1.

## Licence

MIT (see [LICENSE](LICENSE)). The source is public with the rest of this
repository: Logan approved public source under the existing licence on
2026-10-06 (narduk-libs#1520).
