# record-loop

Measures how far the engine's songs sit from real records in a genre. See `docs/record-quality-program.md`.

```bash
cd tools/record-loop
uv run record-loop profile --out ref-house.json ~/.cache/narduk-sound/references/house/keep/*.mp3
uv run record-loop sweep --bin ../../.build/release/narduk-music --genre house --seeds 1-50 --dir /tmp/rl/house --out ours.json
uv run record-loop gap ref-house.json ours.json --trend trend-house.jsonl --label baseline
# Model corpus: counts only on properties where its p50 sits inside the anchor p10-p90.
uv run record-loop validate --anchor ref-house.json --corpus corpus-house.json --out ref-house-merged.json
# One pass: sweep + gap.
uv run record-loop run --bin ../../.build/release/narduk-music --genre house --ref ref-house-merged.json --dir /tmp/rl --trend trend-house.jsonl --label pass-1
# Logan's blind kit: shuffled 45 s clips at -16 LUFS, sources sealed in .key.json.
uv run record-loop listen --out kit/ --engine /tmp/rl/house-{1..10}/mix.wav --model corpus/*.wav --anchor a.mp3 b.mp3
# FAD (fadtk VGGish), each set cut to its gap window. Needs: uv sync --extra fad. Compare run to run on equal n.
uv run record-loop fad --ref a/*.mp3 --eval /tmp/rl/house-*/mix.wav --work /tmp/fad/pass-1
uv run --group dev pytest -q
```

- Reference audio is private, analysis-only, and is never committed. It lives in
  `~/.cache/narduk-sound/references/<genre>/` with a manifest.
- `sweep` renders the A/B song plan (`narduk-music render --song`), so every render leaves the intro. It also logs
  notes (`--notes-out`). `--only` renders a stem.
- The gap colour is green when our median is inside the reference p10–p90, amber when it is within half that spread
  of it, and red otherwise. `lufs` is reported but never coloured, because the -17.5 LUFS trim is a decision.
- Both sides are measured like for like: a 48 s main-groove window (references from 35% in, renders on the song
  plan's second drop at 136 s), with renders round-tripped through 320k MP3 to match the references' codec.
- Pump depth is not steered on yet: a kick-only render reads 48-80 dB because the kick's click lands in the
  300-3000 Hz band. It needs a Demucs non-drum stem first (program section 3.2).
