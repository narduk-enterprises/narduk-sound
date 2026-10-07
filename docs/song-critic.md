# The song critic (NardukMusicCritic)

`NardukMusicCritic` judges a conductor song before anyone hears it, so a player
such as Forever Loop can drop the poor ones. It has two halves and a verdict:

- **Notes** (`SongCritic`, `SongListener`, `SongScore`): how good the song is
  likely to sound, from the notes `DropConductor` writes. Symbolic, so a
  two-minute song scores in a few hundredths of a second.
- **Audio** (`AudioCheck`, `AudioReport`): what a meter hears in a render:
  clipping, clicks, silence, loudness, drum timing and render cost.
- **Verdict** (`SongVerdict`): both, against one `Thresholds` struct, as
  `keep` plus the reasons it was dropped. `repetition` is reported (in the
  score and in `notes`) but never drops a song.

```swift
import NardukMusicCritic

let settings = SongSettings(bpm: 140, genre: .dubstep, seed: 3)
let quick = SongCritic.score(settings: settings, bars: 64)   // notes only
let verdict = SongCritic.judge(settings: settings, seconds: 180)
if !verdict.keep { print(verdict.reasons) }  // ["score 36 (without repetition) under 44"]
```

## Where it came from

The note half is Data Beats' critic,
[`Sources/DataBeatsKit/Critic.swift`](https://github.com/narduk-enterprises/data-beats/blob/31edd3cd5c8cb3c51a30a57ef320df6257ec2c15/Sources/DataBeatsKit/Critic.swift),
ported with its formulas and bands unchanged except:

- `coherence` (does the lead follow a dataset's contour) is left out, with
  `DataComposer` and `SonifyMapping`; its weight is shared out in proportion
  (melody 0.353, repetition 0.235, arc 0.294, events 0.118).
- The lead line comes from the conductor's own notes (below), not from a
  composer's record of what it played.
- `events` counts effect instruments instead of data events.
- Entropy sums run in a fixed order, so a score is identical in every process.

Data Beats still has its own copy; moving it onto this one is a follow-up.

## The note half

Each part is 0 ... 1 and the total is their weighted geometric mean, 0 ... 100,
so a song weak on one axis cannot hide it behind the others (a part is floored
at 0.02). `weakest` names the lowest part. A whole song (`score(notes:...)`,
`score(settings:bars:signals:)`) is multiplied by a length factor: 1 for 1.5 ...
5 minutes, falling to 0.7 under 45 s or over 10 minutes. `SongListener` with a
`window` scores a rolling window of bars with bounded memory (no length factor).

| Part         | What it measures                                                                                                                                            |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `melody`     | The lead on scale degrees: stepwise share (ideal 55 ... 85%), leaps of 3+ degrees (3 ... 15%), range (4 ... 9 degrees), interval entropy, repeated notes.   |
| `repetition` | Bars of the lead whose shape (transposition free) echoes one of the 8 before it: echo or copy share ideal 30 ... 60%; exact copies over 25% are penalised.  |
| `arc`        | Energy spread (10th to 90th percentile), share of drop bars, drops per 64 bars, section variety, and how far energy rises over the 8 bars before each drop. |
| `events`     | Effects (`glitch`, `scratch`, `laser`, `riser`, `tapeStop`, `impact`, `cut`, `vocalChop`): kind entropy in the middle band and spread over 4-bar windows.   |

`raw` keeps every measurement behind the parts.

### The lead line

The conductor writes no melody channel: each genre carries its hook on its own
instrument (`GenreArrangement`). So each bar's lead is the best-ranked carrier
with at least two onsets in the bar (else the best-ranked with any):

1. a sung line: `vox` with a pitch, `vocal` in its `lead` style, `vocalSample`;
2. a single-note guitar: `electricGuitar`, `acousticGuitar` (rock, folk, funk);
3. `keys`, except the pad patch (`voice` 3) (trap, house, chill, techno, UK
   garage, synthwave, lo-fi, and every build);
4. `wobble` (the dubstep, riddim and DnB drops).

Of a chord on one step only its top note counts, and a note a bar or longer is
harmony, never lead. Drums, `sub`, `bassGuitar`, strums, choir and solo vocal
pads and every effect are never lead.

Pitches become scale degrees by the 7-of-12 map round(semitones × 7 / 12)
above a tonic read from the lead's own notes every 8 bars (the tonic that puts
the fewest pitch classes on one degree; the conductor's key is internal and
changes with each track). The map is exact for every diatonic mode but Lydian.
Each carrier is moved by whole octaves so its median sits in one octave, so the
hook passing from the wobble to keys is not a leap.

## The audio half

`AudioCheck.render(settings:seconds:signals:)` renders the song through
`OfflineRenderer`'s tick loop (60 ticks a second, notes 100 ms ahead), driving
`DropSynthCore` itself so the synth's render call can be timed alone. A test
holds it to `OfflineRenderer`'s samples bit for bit. It then renders the song a
second time with only its kicks and snares, to time them. `analyze(_:barSeconds:)`
meters any `RenderedAudio` (no drum timing or cost).

| Measure      | Definition                                                                                                                                                                                                                                                                                                                        |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Clipping     | Samples on either channel at or above 0.999 full scale.                                                                                                                                                                                                                                                                           |
| Clicks       | Second difference \|x[n] − 2x[n−1] + x[n−2]\| at least 0.02 and over 4 times the largest one anywhere else within 30 ms either side (3 samples guarded). A snare's noise, a drum attack and a saw's period resets bring jumps of their own size, so they pass.                                                                    |
| Silence gaps | Runs of 10 ms windows under −60 dBFS on both channels longer than one bar.                                                                                                                                                                                                                                                        |
| Loudness     | RMS of the whole song and of its loudest second, both channels, from `NardukSoundAnalysis.Loudness` per second, summed in Double; and the peak.                                                                                                                                                                                   |
| Drum timing  | In the drums-only render, each kick and snare's onset (first difference reaching 10% of its peak, or 1.5 times the level before it, within −5 ... +40 ms) against its due sample: the grid step on the synth's clock, plus its swing, plus the limiter's delay. Worst and mean \|offset\| in ms, and the largest swing asked for. |
| Render cost  | Wall time of each `DropSynthCore.render` call (800 frames, a 16.7 ms budget at 48 kHz) as worst, mean and blocks over budget, and the slowest tick's conductor work.                                                                                                                                                              |

## The verdict thresholds

All in `SongVerdict.Thresholds`; nil switches a check off.

`repetition` is reported but never judged (Logan, 2026-10-07: "report it,
don't drop for it"). The conductor repeats its hook bar for bar, so the part is
0 for most loop songs (see Limits). `minTotal` therefore holds
`SongScore.totalWithoutRepetition`, the weighted geometric mean of melody, arc
and events with the same length factor; `minPart` never applies to
`repetition`; and when `repetition` is the weakest part the verdict says so in
`notes`, not in `reasons`. `SongScore.total` keeps all four parts, as Data
Beats scores it.

| Threshold             | Default | Why                                                                                                                                                                          |
| --------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `minTotal`            | 44      | On `totalWithoutRepetition`: drops about the bottom quarter of conductor songs (30 seeds a genre, 90 bars: 10th percentile 37, 25th 44, median 52; genre medians 45 ... 60). |
| `minPart`             | off     | For melody, arc and events only.                                                                                                                                             |
| `maxClippedSamples`   | 0       | The limiter should never let one through.                                                                                                                                    |
| `maxClicks`           | 0       | A click is an audible fault.                                                                                                                                                 |
| `maxSilenceGaps`      | 0       | A bar of nothing in a song is a dropout.                                                                                                                                     |
| `minRMSDB`/`maxRMSDB` | −30/−6  | Every genre measured −10.6 ... −18.8 dBFS.                                                                                                                                   |
| `maxDrumOffsetMs`     | 5       | Offline renders measure under 0.2 ms; 5 ms is well under a flam.                                                                                                             |
| `maxOverBudgetShare`  | off     | Depends on the machine and build (debug is ~30 times slower); set it where the song will play.                                                                               |

## What the first measurements say (2026-10-07, seed 3, three minutes)

- **Drums are on the grid offline.** Every genre's worst kick or snare is within
  0.15 ms of where the synth was asked to play it. What is large is the swing
  the conductor asks for: up to 67 ms late in lo-fi, 51 ms in chill, 37 ms in UK
  garage. If "drums off" is heard live, it is that swing or the live engine's
  pump, not the synth.
- **Clicks came from the `cut` stutter, and are fixed.** Every click (three in
  dubstep, two in DnB, two in synthwave) was a one-sample jump of 0.6 ... 1.0
  inside a master `cut` stutter whose amount pitches the repeat up: the sped-up
  read wraps back to the slice's start partway through each slice, and only
  the slice's own edges were faded. `MasterCut` now fades over each wrap too
  (a millisecond, like a slice edge); at rate 1 the sound is unchanged, and no
  golden render moved. After the fix every genre at seed 3 has zero clicks.
- **Render cost is small and its spikes are the machine.** Release renders run
  0.3 ... 0.6 ms a block (3% of budget) on a Mac15,10 MacBook Pro. 17 ... 104 ms
  spikes appeared only while other builds loaded the machine, at different
  times on each run; run alone the worst block was 0.4 ... 1.7 ms. A debug build
  is roughly 30 times slower, which explains a 32 ms tick in a debug run.
- **Folk seed 3 has a 3.1 s silence** in its arrangement.

The verdicts after the cut fix (release, the machine otherwise quiet; every
genre has 0 clipped samples and 0 clicks, its worst drum within 0.15 ms and
its worst render block within 1.5 ms):

| Genre       | Total | Judged | Weakest    | Keep | Reason            |
| ----------- | ----- | ------ | ---------- | ---- | ----------------- |
| dubstep     | 58    | 52     | melody     | yes  |                   |
| riddim      | 30    | 69     | repetition | yes  |                   |
| drumAndBass | 51    | 52     | melody     | yes  |                   |
| trap        | 32    | 36     | melody     | no   | score 36 under 44 |
| house       | 33    | 79     | repetition | yes  |                   |
| chill       | 50    | 48     | melody     | yes  |                   |
| techno      | 24    | 51     | repetition | yes  |                   |
| ukGarage    | 35    | 47     | repetition | yes  |                   |
| synthwave   | 26    | 42     | repetition | no   | score 42 under 44 |
| lofi        | 27    | 59     | repetition | yes  |                   |
| rock        | 26    | 48     | repetition | yes  |                   |
| folk        | 26    | 56     | repetition | no   | 3.1 s silence     |
| funk        | 26    | 57     | repetition | yes  |                   |

## Limits

- "Good" has no ground truth: the parts are heuristics from music cognition
  (Berlyne's inverted U, stepwise melody, repetition with variation, an arc).
- **`repetition` punishes loop music.** The conductor repeats its two-bar hook
  bar for bar, so exact copies run 50 ... 90% and the part is 0 for most rock,
  folk, funk, house, techno and lo-fi songs. That is Data Beats' penalty, kept
  as ported in the score; the verdict does not judge it (above).
- Drum timing is measured offline, where notes always arrive early. It cannot
  see late notes from a stalled main-thread pump on a device.
- Render cost is wall time on whatever runs the check, so it varies with load.
- Without input the conductor never leaves its intro, so the convenience entry
  points play `SongCritic.energyWave` (a rise and fall every 32 bars) when given
  no signals.

## Cost

Release, one genre at a time, Mac15,10: two minutes of song judged (two renders
and the meters) in 1.7 ... 2.6 s. The notes alone
take about 0.05 s even in a debug build. `SongVerdictTests` holds each genre to
8 s in release and, in debug (the gate), the notes-only score to 1 s.
`NARDUK_CRITIC_TABLE=1 swift test -c release --filter SongVerdictTable` prints
the verdict table.
