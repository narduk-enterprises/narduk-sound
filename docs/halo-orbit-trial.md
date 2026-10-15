# Halo orbit: bounded native motion trial

`IntenseKind.haloOrbit` is an opt-in redesign of Halo. The original `.halo` shader is unchanged. Both appear in
SoundGallery through its existing `IntenseKind.allCases` tiles; consumer adoption is a separate pin/picker change.

The picture is a breathing glass core inside a tilted spectrum crown, with a sparse foreground orbit. Deliberate
symmetry keeps one focal point inside landscape and portrait cards. Blue is the body, turquoise is the accent,
near-black is the negative space, and restrained white highlights convey material and depth. Colors come from the
existing palette contract; the comparison locks the same Ocean palette on both presets.

- Bass (band 0.05): the size and light of the focal core.
- Mids (0.4): the crown radius; the full spectrum sets the lengths of 48 rounded ribs.
- Highs (0.8) and hats: six small orbital beads, subordinate to the core.
- Kick: an immediate core swell followed by the state's existing release.
- Snare: one expanding, fading arc, localized to the crown.
- Beat phase: a small core breath between hits.
- Drop amount: a bounded crown expansion.
- Travel: continuous rib and bead orbits; time: slow plasma and counter-drifting ambient stars.
- Waveform: a fine rim contour. Calm: the existing intensity scales the motion and hit amplitude.

No new smoothing, audio inputs, wall clock, per-frame Swift state or allocations are introduced. There is no
full-screen flash in the trial. Palette transitions remain owned by `SoundVisualState`.

## Guidance and review

Read as design guidance, without installing or executing their code:

- [iart-ai motion-art-direction](https://github.com/iart-ai/motion-design-skills/blob/main/skills/motion-art-direction/SKILL.md):
  one motion language, hero/support/texture hierarchy and restraint.
- [iart-ai shot-composition](https://github.com/iart-ai/motion-design-skills/blob/main/skills/shot-composition/SKILL.md):
  deliberate symmetry, negative space, layered depth and aspect-safe framing.
- [iart-ai color-motion](https://github.com/iart-ai/motion-design-skills/blob/main/skills/color-motion/SKILL.md):
  a small palette with highlights and shadows doing the work.
- [LottieFiles motion-design](https://github.com/LottieFiles/motion-design-skill/blob/main/skills/motion-design/SKILL.md):
  primary/secondary/ambient choreography, emotional intent and consistent easing. UI duration tables are guidance,
  not replacements for NardukSound's audio envelope timing.

Pass one was too dim at card size. Pass two enlarged the core and crown, raised their highlights, enlarged the six
beads and added a foreground arc after core occlusion to clarify depth. The final pass flattened the orbit from
0.64 to 0.52 so that its foreground arc crosses the lower hemisphere. The original waveform and palette remain
observable, with lower competing motion. Review the native intro, build, drop and settled frames before adoption.

## Reproduce the native comparison

On a macOS host with a Metal device, from the package root:

```sh
HALO_ORBIT_OUT=/absolute/path/to/a/new-empty-directory \
  swift test --filter HaloOrbitComparisonTests
swift test --filter 'HaloOrbitTests|IntenseVisualizerTests|IntenseSafetyTests|IntenseMotionTests'
python3 scripts/swift-quality.py
```

The opt-in harness synthesizes an original 24-second phrase at 120 BPM with seed 7, procedural drums, sub and
electric piano. It opens no audio device and uses no recorded bank. The source WAV, AAC and 60 Hz `.lights` timeline
are preserved. Both native H.264/AAC MP4s use the same audio and timeline, 960×540 at 30 fps, Ocean palette, default
visual seed, and full render scale (`gpuBudgetMilliseconds: nil`). The same `SoundVideoExporter` and Metal encoders
used by Beat Blaster render the pictures. External video tools only compose labels and the comparison container.

`native-report.json` records export wall time and render-only command-buffer GPU durations. The first 30 frames
warm up the GPU, followed by 690 measurements across the whole clip. The CSVs record the video clock, state kick
envelope and timeline kick count for sync checks. Export wall time includes codec, analysis and disk work, and
must not be treated as an isolated GPU speedup. Desktop results do not constitute tvOS testing.

The test-only `DropArrangerTests` change splits an existing arithmetic expression into locals so Swift 6.2 can
type-check the assertion. It preserves its original integer means and comparison; production music code is unchanged.

This is a visualizer trial, separate from SIGNAL ATLAS. Keep the high-quality comparison master, make a faststart
H.264/AAC delivery copy under 15 MB, fully decode both, and verify matching audio packets and stream timing.
The existing exporter loses the AAC priming metadata from `AudioFileWriter.writeM4A` on this Intel Mac, delaying
the exported sound by 44 ms. Keep the raw exports for provenance. Encode the preserved original WAV to AAC once
with a muxer that retains priming, then remux that identical audio track into both native clips (`-c:v copy`), the
comparison master and delivery copy. The renderer and its frame timing remain unchanged. Verify decoded audio
lag against the original PCM; container durations alone do not prove sync. This is a comparison delivery fix,
not a change to the shared exporter.

No merge, release or deployment is part of this trial.
