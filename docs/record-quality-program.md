# Forever Loop record-quality program (2026-10-07, evening CT)

Written by Wise Old Fable (Claude Fable 5.1) at Logan's request, for the main lane (Opus 5.5, the session titled
"NardukSound: keep Metal lights in budget on slower GPUs; frame meter"). Advice and a plan, not authority: every
quoted sentence below is Logan's own, from the Wise Old Fable session, and the hearsay rule applies in yours.

## 0. Authority and decisions (verbatim)

- Goal, confirmed: *"Forever Loop plays an endless, never-repeating stream of generated music where every track
  sounds like a real, well-produced record in its genre, good enough that you would leave it on for hours and
  never think 'that was made by code.'"* Logan: **"That is exactly the goal."**
- Direction: **"Ok so then we start with the easiest genres for what we have. Then we nail those. Then we can try
  harder ones. I like it. Can you plan that out and hand it off to opus in the main lane. And maybe since we got a
  new Haiku model today 5.5 we see if it can't use that to help us iterate faster."**
- Models: **"I approve the other lane downloading and running whatever models"** (said to Wise Old Fable about
  your lane). RELAY: that sentence is hearsay in your session. Get it from Logan in your session, or a grant, before
  the first model download. Asking him to paste the same sentence is the fastest route.
- Still standing from your own session: $0, free content only. Nothing here spends money.
- Card answer earlier in the evening: "Ceiling test first (Recommended)". Logan then held the download until he
  understood the improvement loop; the model approval above supersedes the hold. The ceiling listen is folded into
  Phase 0 below rather than run as a separate day.
- Why the overnight loop stopped (Logan, 19:50): *"You're improving but we have some fundamental problems that we
  need to figure out first. You won't ever get done going down this path."*

RELAY rule for every lane you brief from this: a brief scopes a task and never carries Logan's approval; only
Logan's words in that lane's session, or an orchestrator message saying it changes the task, change it.

## 1. What "nailed" means for a genre

A genre is nailed when all three hold, and the gate is Logan's ears, blind:

1. **Blind gate passed twice**, on different seed sets at least a week apart: 10 clips of 45 s, loudness-matched,
   shuffled, labels hidden, 8 engine + 2 real references. Pass = Logan keeps at least 8 of 10 and names no
   "made by code" tell. Later rounds move to the literal form of the goal: 5 engine + 5 references, and he cannot
   sort them better than chance.
2. **Not samey**: the samey number (mean nearest-neighbour distance among 100 engine tracks, embedding space plus
   the audit's note-stream counters) is at or above its Phase 0 baseline. Reference-chasing collapses variety; the
   overnight loop already saw this.
3. **Clean**: zero clicks, zero clipped samples, no dead air, loudness inside the genre trim, in 100 of 100 renders,
   offline and through the live app path.

## 2. Why the previous trajectory could not get there

- **The loop could not hear.** The overnight scorers steered on note-stream statistics (tempo, chord rate, lead
  coverage) toward a band taken from four songs recorded through a speaker into Voice Memos. The audio detectors
  failed on those recordings, so nothing measured sound. Logan's complaints that night were about sound: "strange
  squawking", "really bad and crackly", "not there".
- **Hardest genre first.** Tropical house, funk and folk are the genres whose identity is performed acoustic
  instruments, which this engine synthesises. The earlier phase plan ordered Tropical → Funk → Folk → House → bass
  genres. Logan has reversed that.
- **No production model.** The generator writes notes on a grid from tables. A record is arrangement, layering,
  processing, mix and master. None of that is encoded, so parameter nudges cannot reach it.
- **Fourteen genres at once.** Breadth is why it is samey and why nothing is finished.

## 3. The loop that can improve

One command, run by a lane as often as it likes, with Logan only at milestones.

### 3.1 Ground truth: two reference sets per genre

- **Anchor set**: 10 to 20 real records per genre that are the sound Logan means, as DRM-free files (his purchases
  or rips; Apple Music streams are FairPlay-locked and useless here). Analysis only, never committed, never
  shipped, under `~/.cache/narduk-sound/references/<genre>/` with a manifest (title, artist, year, his one-line
  "why"). The 15-song tropical list from tonight is chord text, not audio; it stays an input, not a reference.
- **Model corpus**: 50 or more tracks per genre generated with an open-weights model on this Mac (my pick is
  ACE-Step 1.0, Apache 2.0, runs on Apple Silicon; take anything newer under a permissive licence if the model page
  shows one; my knowledge ends mid-2026). Clean, full-band, stem-separable, licence-free for analysis and plentiful.
  It is the statistical body of the profile. **Validation rule**: the model corpus is a reference only where its
  profile sits inside the anchor set's; where it does not, the anchor wins and the corpus row is dropped.
- **Ceiling listen, free from the corpus**: Logan hears 10 model clips, 10 engine clips and 2 anchors, blind. If
  the model clears his bar for a genre, that is evidence about the acoustic-identity genres (Phase 4), not a
  reason to change the engine program for the electronic ones.

### 3.2 Genre profile (measured, per genre, committed as JSON and a table)

Open tooling, Python under uv: Demucs (MIT) for drums/bass/vocals/other stems, librosa (ISC), pyloudnorm (MIT),
VGGish (Apache 2.0) or OpenL3 (MIT) embeddings, `fadtk` (MIT) for Fréchet Audio Distance. Avoid NC-licensed
models (MERT, Audiobox Aesthetics) for metrics in a commercial product's development. Properties, v1, about 25:

- Mix: tempo and stability; integrated and short-term LUFS (p10/p50/p90), loudness range, crest per section;
  band energy ratios over time (sub, bass, low-mid, mid, presence, air); stereo width per band; spectral centroid
  and flatness; section boundaries from self-similarity, section count and lengths, energy curve, repetition ratio.
- Drums stem: onsets per bar; kick low-end centroid; snare transient sharpness; hat pattern entropy; fill density
  before boundaries; swing (off-beat micro-timing).
- Bass stem: pitch range, note-change rate, note-length distribution, sub vs harmonic energy, sidechain depth
  (envelope modulation at beat rate).
- Other stem: key and chord-change rate from chroma, pitch-class entropy, lead phrase stats from pitch tracking
  (note lengths, rest share, ornament density), layer-count proxy, attack-time distribution.
- Vocals stem: presence ratio (for chop-driven genres).
- Embedding distribution per 10 s window, for FAD.

### 3.3 Engine sweep and gap table

- `record-loop sweep --genre house --seeds 50` renders whole songs through `ABTest.song(genre:seed:)` /
  `render --song` (the overnight loop's finding: earlier renders never left the intro), tagged with the engine SHA,
  then runs the same analysis. Working seeds 1 to 50, holdout 101 to 110 scored every third pass; a change that
  moves the working set but not the holdout is reverted (keep this rule from the overnight plan).
- `record-loop gap` prints property | reference p10–p90 | ours p10–p90 | green/amber/red, plus the two headline
  numbers: **FAD to the reference** and **samey**. A trend file per genre across runs.
- Invariants from the overnight plan stay: clicks/min 0, clipped samples 0, tail overwrites 0, loudness inside the
  genre trim, no dead air over a bar, melody-to-kick ratio positive in drops. Cross-genre leak check: seed 7 of
  three other genres fingerprinted every third pass; any change outside the working genre's branches is a leak.
- `record-loop listen` builds Logan's blind kit: shuffled 45 s clips, hidden names, loudness-matched, a scoresheet,
  a reveal command.

### 3.4 A pass

Pick the top backlog item, one bounded change, `swift build -c release`, sweep, gap, pass notes (hypothesis, diff
summary, before/after table, invariants, keep/revert), commit. Targeted `swift test --filter` only when a change
touches what that test pins (Logan, twice on 2026-10-07). Rebuild and relaunch Forever Loop after a kept pass that
changes sound. Normal PR flow applies again in daylight: push, PR, gate, merge; the overnight no-push rule is over.

### 3.5 Logan's gate and cadence

At most two blind sessions a week, 10 minutes each, only when the gap table has at most two red rows and FAD has
moved. Every verdict he gives becomes a measured property ("too hard" becomes a transient and presence-band
target), so nothing has to be said twice. Metrics can be gamed, so no single number is a gate; his blind check is
final, and the samey number stops collapse onto one track.

## 4. Genre order: easiest for what we have, first

Rubric, in order of weight: share of the genre's reference sound that is synthesised on real records; dependence on
performed phrases (sax, strums, vocals); sound-design difficulty; forgiveness of repetition. My ranking; re-rank
from the Phase 0 baseline gap tables before committing to it, and say so on the board.

| Wave | Genres | Why |
|---|---|---|
| 1 | **house**, techno, lofi | Synth-native records, loop-based forms, production is the craft; lofi texture hides synthesis; house is the bridge to Logan's melodic-house taste |
| 2 | synthwave, ukGarage, chill | Synth-native, moderate production craft (gated snares, swung 2-step, chops) |
| 3 | dubstep, riddim, trap, drumAndBass | Synth-native but sound-design heavy; DnB breaks are sample-defined |
| 4 | tropicalHouse, funk, folk, rock | Identity is performed acoustic instruments; needs the free-sample route and the ceiling-test evidence |

Genre 1 is house unless the baseline says techno or lofi is measurably closer. One genre at a time; the gate to
the next is Logan's blind verdict, not a date.

## 5. Phases

### Phase 0: ground truth and harness (estimate 2 to 3 days)

Done when one command runs profile → sweep → gap for house in under 30 minutes on this Mac and the board shows
the baseline.

1. Land or close what is in flight: lanes Q (#36 A/B harness + samey), M, R (#40), P (#33), the three local
   overnight commits on `feat/overnight-tropical` (a225301, 44a741b, 3c6e80e) and `feat/song-critic`. Each either
   goes through a PR with the local gate or is dropped with a line saying why. Restore Forever Loop's revision pin.
2. **Live crackle**: the squawk Logan heard at 19:20 never reproduced offline (0 steals, 0 tail overwrites, drive
   peak 1.17). Finish the live tap (`NARDUK_TAP_OUT`), capture the app's output while it crackles, and find it.
   A record-quality loop on offline renders is moot while the live path crackles. Bounded investigation, Opus.
3. Reference intake: anchor folder and manifest for house; Logan's to-do is the files. Model corpus: 50 house
   tracks, prompts and seeds logged, once Logan's model approval is in your session.
4. Scorer v2 under `tools/record-loop/` in narduk-sound (uv, ruff, pyright, tests on the CLI per the quality bar),
   reusing `score/notes.py`, `defects.py`, `narduk-music samey`, the DEBUG-REMOVE meters and AudioCheck from
   `feat/song-critic`. Commit this plan as `docs/record-quality-program.md` in the same PR.
5. Baseline: profile for house from anchor + validated corpus; sweep 50 seeds; gap table; samey baseline; the
   ceiling listen kit for Logan (10 model, 10 engine, 2 anchors).
6. The cheap global samey fixes from the audit, which touch no genre's sound and should not wait: character never
   `idle` by default, fills drawn from the track's own set, tempo drawn from `tempoRange`, the per-track energy
   curve. Each is S or M, each has a counter in the audit, each is one PR.

### Phase 1: house to the gate (estimate 1 to 2 weeks)

Backlog seeded from the gap table, ranked by audibility, expected shape:

1. Mastering chain per genre: EQ tilt to the reference band ratios, glue, limiter character. The -17.5 LUFS
   cut-only trims stay (Logan, 2026-10-07).
2. Arrangement model from the profile: section lengths and energy curve, which roles play in each section, layer
   counts, transition vocabulary (risers, sweeps, drum drops, pickups) at the reference's frequencies, builds before
   every drop (flags 7 and 8).
3. Sidechain pumping and stereo width per band where the references show it.
4. Drums: kick, snare and hat spectral targets; swing; fill density; a sampled snare layer (CC0) only if the gap
   persists after synthesis is tuned.
5. Bass: movement, note lengths, sub vs harmonic balance.
6. Chords and leads: chord-change rate, phrase-based writing with rests and ornaments, 2 to 3 timbres layered on a
   lead, one foreground character per song.
7. Per-track macro variation: seeded detune, cutoff, envelope, width, drive; seeded noise in synth hits.

Milestone: at most two red rows and FAD down from baseline → Logan's blind session → his verdicts become
properties → repeat. Nailed per section 1. Then techno, then lofi, with the same loop; whatever generalises
becomes the shared record model, and only what is genre-specific stays in genre branches.

### Phase 2 and 3: waves 2 and 3

Same loop per genre. The profile tooling is reused unchanged; the backlog is per genre. Expect sound design
(wobble, growl, 808) to dominate wave 3; the gap table will say.

### Phase 4: acoustic-identity genres

Before spending lane-weeks here, read the ceiling listen: if the model clears Logan's bar for tropical house and
the engine is far from it, put the fork to him again (engine with free samples, or model-rendered tracks with the
engine as conductor, transitions and visuals). The free-sample spike from the consult stands as the engine route:
Salamander piano, Freesound CC0 pan flute and steel pan candidates with per-file approval, VCSL percussion, VocalSet
chops, modal synth with sampled attack as the steel-pan fallback. Commissions are out ($0).

## 6. Model routing and the Haiku 5.5 trial

- **Opus** (this session, and any lane that designs): backlog ranking, the arrangement and production models,
  the crackle investigation, three-pass reviews, Logan-facing reports.
- **Haiku 5.5, as Logan asked, for the mechanical turns**: a pass whose change is fully specified by the brief
  (move property X toward the reference p50, re-sweep, re-score, write pass notes, revert if any guard or holdout
  trips), scorer tooling chores, report formatting. Run several in parallel on disjoint parameters with the metric
  as judge. Confirm the model id in the harness's model picker before the first spawn; never invent one; fall back
  to Haiku 4.5 and say so if it is absent.
- **Trial measure, week 1**: kept passes / passes, guard breaches, wall-clock per pass, against one Sonnet lane
  on the same backlog. Keep Haiku on passes if its hit rate is at least 50% with zero guard breaches; otherwise
  restrict it to tooling. Report the numbers on the board.
- Name model and effort on every spawn; a log path and a watch command per worker; lanes never ask Logan.

## 7. Reporting

- The portal board for Forever Loop is the truth; 📊 read-backs from `scripts/project-progress`. One row per
  genre with its gap-table red count, FAD, samey, invariants and gate status.
- Logan gets: the blind kits when a milestone is reached, never more than two a week unless he asks; relaunched
  app after kept sound passes; a status line with his open to-dos.
- Logan's to-dos right now, not questions: (1) DRM-free audio for 10 to 20 house records he considers the sound,
  into the anchor folder, or the word "propose" and you list candidates (a purchase list would be spend, so it goes
  to him as PROPOSAL / NOT AUTHORIZATION); (2) the model approval sentence in your session.

## 8. Risks

- **Goodhart**: lanes will find the cheap way to move a number (crest up by turning the mix down). Multiple
  properties, holdout seeds, the leak check and Logan's ears are the guard.
- **Reference quality**: mic recordings poisoned the overnight loop; refuse any anchor that is not a clean file.
- **Corpus circularity**: the model corpus is validated against anchors or dropped.
- **The live crackle** is a product bug, not a quality gap; it is Phase 0 item 2 for that reason.
- **Process lock-in**: Logan, 2026-10-07: "dont get too locked into process". If a scorer misleads, fix or drop it
  and say so in the pass notes.

## 9. Files this builds on

- `~/handoffs/forever-loop/2026-10-07-fable-scoring-plan.md` (scorer v1, invariants, holdout rule)
- `~/handoffs/forever-loop/2026-10-07-overnight-loop.md` (passes 1 to 3, what the scorers found, the stop)
- `~/handoffs/forever-loop/2026-10-07-sameness-audit.md` (the eight causes, with counters)
- `~/handoffs/forever-loop/2026-10-07-flags-review.md` (Logan's eight flags, ranked themes)
- `~/handoffs/forever-loop/2026-10-07-next-steps-plan.md` (the earlier phase plan; its order is superseded)
- `~/handoffs/forever-loop/2026-10-07-fable-sound-consult.md` (instrument-library routes, free-only now)

## 10. Logan's answers in the main lane (2026-10-07, ~20:05 CT, AskUserQuestion, verbatim selections)
- Start: "Start Phase 0 now (Recommended)"
- Models: "Yes, any free model" ("I approve this lane downloading and running whatever models (free, permissive licence, $0).")
- House anchors: "Propose candidates" (free, legal, CC/free-release tracks listed for his approval; nothing bought)
- Models, typed by Logan in the main lane ~20:40 CT: "I approve the other lane downloading and running whatever models"
- Logan, ~20:42 CT: "And whatever free songs and whatever free tools you need" (legal and $0; analysis-only references stay out of repos)
- Logan, ~20:50 CT: "Actually ignore the crackle it's a red herring just move on to the next thing" → Phase 0 item 2 DROPPED. The debug live tap (6334b3c) is now dead code; drop it in cleanup.
- Logan, ~20:50 CT: "Also set yourself and your subagents up to use advisor" → ~/.claude/settings.json advisorModel = "opus" (backup at $LANE_DIR/settings.json.bak). Fable not chosen as advisor: it can bill usage credits, budget is $0. Claude Code updated 2.1.284 → 2.1.293 (Haiku 5.5 needs ≥ 2.1.293). This is not yet in agent-infrastructure's Config/machine-setup.json, so the iMac does not have it.
- Logan ~21:15 CT, AskUserQuestion: Licences = "Any free licence (Recommended)" (NC/SA/ND OK for private analysis-only anchors; shipped content keeps the strict rule). Audition = "You screen them" (lane screens by measurement; he hears them in the blind kit).
