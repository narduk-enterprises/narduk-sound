# VocalSet

The recorded voice behind `Instrument.vocalSample` (`vocalsamples.bin`) is cut
from **VocalSet**.

- **Title:** VocalSet: A Singing Voice Dataset
- **Authors:** Julia Wilkins, Prem Seetharaman, Alison Wahl, Bryan Pardo
  (Northwestern University)
- **Source:** https://zenodo.org/records/1193957 (DOI
  [10.5281/zenodo.1193957](https://doi.org/10.5281/zenodo.1193957))
- **Licence:** Creative Commons Attribution 4.0 International (CC BY 4.0),
  https://creativecommons.org/licenses/by/4.0/
- **Singer used:** `female2` only.

Credit line for an app: "Vocal samples from VocalSet by Wilkins, Seetharaman,
Wahl and Pardo (CC BY 4.0), modified."

## Changes made to the recordings

The 44.1 kHz source files were modified for this package: steady notes were
selected from the scale recordings, the syllables were cut from two excerpts,
and three fast scale runs were trimmed. Everything was downsampled to 22.05 kHz,
mixed to mono, level-matched, faded at the edges, given loop points with a short
crossfade baked into the loop end (the sustains), and packed as 16-bit PCM into
one file. They are pitch-shifted and looped at playback. No other processing.
`scripts/build_vocal_samples.py` reproduces the file from the dataset;
`scripts/vocalset_fetch.py` fetches single files from the archive (the 2.1 GB
source is never stored in the repository).

## Source files used

- `scales/straight/f2_scales_straight_a.wav` (5 clips)
- `scales/straight/f2_scales_straight_o.wav` (5 clips)
- `scales/straight/f2_scales_straight_u.wav` (5 clips)
- `scales/straight/f2_scales_straight_e.wav` (5 clips)
- `scales/straight/f2_scales_straight_i.wav` (5 clips)
- `scales/vibrato/f2_scales_vibrato_a.wav` (5 clips)
- `scales/vibrato/f2_scales_vibrato_o.wav` (5 clips)
- `scales/vibrato/f2_scales_vibrato_u.wav` (5 clips)
- `scales/vibrato/f2_scales_vibrato_e.wav` (5 clips)
- `scales/vibrato/f2_scales_vibrato_i.wav` (5 clips)
- `scales/belt/f2_scales_belt_a.wav` (5 clips)
- `scales/belt/f2_scales_belt_o.wav` (5 clips)
- `scales/belt/f2_scales_belt_u.wav` (5 clips)
- `scales/belt/f2_scales_belt_e.wav` (5 clips)
- `scales/belt/f2_scales_belt_i.wav` (5 clips)
- `excerpts/straight/f2_row_straight.wav` (10 clips)
- `excerpts/vibrato/f2_row_vibrato.wav` (10 clips)
- `excerpts/straight/f2_dona_straight.wav` (10 clips)
- `excerpts/vibrato/f2_dona_vibrato.wav` (10 clips)
- `scales/fast_forte/f2_scales_c_fast_forte_a.wav` (1 clip)
- `scales/fast_forte/f2_scales_c_fast_forte_o.wav` (1 clip)
- `scales/fast_piano/f2_scales_c_fast_piano_a.wav` (1 clip)
