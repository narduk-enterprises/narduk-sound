# record-loop

Measures how far the engine's songs sit from real records in a genre. See `docs/record-quality-program.md`.

```bash
cd tools/record-loop
uv run record-loop profile --out ref-house.json ~/.cache/narduk-sound/references/house/keep/*.mp3
uv run record-loop sweep --bin ../../.build/release/narduk-music --genre house --seeds 1-50 --dir /tmp/rl/house --out ours.json
uv run record-loop gap ref-house.json ours.json --trend trend-house.jsonl --label baseline
uv run --group dev pytest -q
```

- Reference audio is private, analysis-only, and is never committed. It lives in
  `~/.cache/narduk-sound/references/<genre>/` with a manifest.
- `sweep` renders the A/B song plan (`narduk-music render --song`), so every render leaves the intro. It also logs
  notes (`--notes-out`). `--only` renders a stem.
- The gap colour is green when our median is inside the reference p10–p90, amber when it is within half that spread
  of it, and red otherwise. `lufs` is reported but never coloured, because the -17.5 LUFS trim is a decision.
