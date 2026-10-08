"""record-loop: profile references, sweep engine renders, print the gap.

    record-loop profile --out ref.json FILE...             measure audio files (mp3, wav, flac)
    record-loop sweep --bin narduk-music --genre house --seeds 1-50 --dir renders/ --out ours.json
    record-loop gap ref.json ours.json [--trend trend.jsonl --label pass-3]
    record-loop validate --anchor anchor.json --corpus corpus.json --out ref.json
    record-loop run --bin narduk-music --genre house --ref ref.json --dir renders/ [--trend t.jsonl --label pass-3]
    record-loop listen --out kit/ --engine a.wav ... --model b.wav ... --anchor c.mp3 ...

A profile is {"tracks": {path: {property: value}}, "source": ...}. Measurements are cached next to each audio file
(<file>.<window>.<codec>.features.json, keyed by size and mtime), so re-profiling a reference set is free.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

from record_loop import features

# Reported, never coloured: lufs and clipping are set by a level decision rather than the sound (the engine's -17.5
# LUFS trim, Logan 2026-10-07), and sections_per_min reads about 1.25 for any 48 s window (the novelty peak picker
# always finds a few peaks), so it cannot tell a sectioned track from a flat one.
INFO_ONLY = {"lufs", "clipped_ratio", "sections_per_min"}


def _window(path: str, window: str | None) -> tuple[float, float | None]:
    """'35%:48' starts 35% into the file; '136:48' starts at 136 s. Both measure 48 s. None measures everything."""
    if not window:
        return 0.0, None
    start, _, length = window.partition(":")
    if start.endswith("%"):
        import soundfile as sf

        try:
            total = sf.info(path).duration
        except RuntimeError:
            import librosa

            total = librosa.get_duration(path=path)
        offset = total * float(start[:-1]) / 100
    else:
        offset = float(start)
    return offset, float(length) if length else None


def _encoded(path: str, codec: str | None) -> str:
    """Round-trip through the references' codec so codec loss is not measured as a sound difference."""
    if not codec or not path.endswith(".wav"):
        return path
    out = path[: -len(".wav")] + f".{codec}.mp3"
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(path):
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", path, "-c:a", "libmp3lame", "-b:a", codec, out],
            check=True,
        )
    return out


def _load(path: str, window: str | None = None) -> tuple[np.ndarray, int]:
    import librosa

    offset, duration = _window(path, window)
    y, sr = librosa.load(path, sr=None, mono=False, offset=offset, duration=duration)
    y = np.atleast_2d(y)
    if y.shape[0] == 1:
        y = np.vstack([y, y])
    return y.T.astype(np.float64), int(sr)


def measure(path: str, window: str | None = None, codec: str | None = None) -> dict[str, float]:
    source = _encoded(path, codec)
    tag = f"{window or 'all'}.{codec or 'raw'}".replace(":", "_").replace("%", "pct")
    cache = Path(f"{path}.{tag}.features.json")
    st = os.stat(source)
    key = f"{st.st_size}:{int(st.st_mtime)}:v4"
    if cache.exists():
        cached = json.loads(cache.read_text())
        if cached.get("key") == key:
            return cached["features"]
    stereo, sr = _load(source, window)
    feats = features.all_features(stereo, sr)
    cache.write_text(json.dumps({"key": key, "features": feats}))
    return feats


def _measure(job: tuple[str, str | None, str | None]) -> dict[str, float]:
    return measure(*job)


def _profile(paths: list[str], jobs: int, window: str | None = None, codec: str | None = None) -> dict:
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        return dict(zip(paths, pool.map(_measure, [(p, window, codec) for p in paths])))


def cmd_profile(args: argparse.Namespace) -> int:
    paths = sorted(str(Path(p)) for p in args.files)
    tracks = _profile(paths, args.jobs, args.window, args.codec)
    meta = {"source": "files", "window": args.window, "codec": args.codec}
    Path(args.out).write_text(json.dumps({**meta, "tracks": tracks}, indent=1))
    print(f"profiled {len(tracks)} files -> {args.out}", file=sys.stderr)
    return 0


def _seeds(text: str) -> list[int]:
    out: list[int] = []
    for part in text.split(","):
        lo, _, hi = part.partition("-")
        out += list(range(int(lo), int(hi or lo) + 1))
    return out


def _render(job: tuple[str, str, int, float, str]) -> str:
    binary, genre, seed, variety, folder = job
    d = Path(folder) / f"{genre}-{seed}"
    d.mkdir(parents=True, exist_ok=True)
    wav = d / "mix.wav"
    scenario = d / "s.json"
    scenario.write_text(json.dumps({"genre": genre, "seed": seed, "variety": variety}))
    subprocess.run(
        [
            binary,
            "render",
            "--scenario",
            str(scenario),
            "--song",
            "--notes-out",
            str(d / "notes.jsonl"),
            "--out",
            str(wav),
        ],
        check=True,
        capture_output=True,
    )
    return str(wav)


def cmd_sweep(args: argparse.Namespace) -> int:
    started = time.time()
    jobs = [(args.bin, args.genre, s, args.variety, args.dir) for s in _seeds(args.seeds)]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        wavs = list(pool.map(_render, jobs))
    rendered = time.time()
    tracks = _profile(wavs, args.jobs, args.window, args.codec)
    sha = subprocess.run(
        ["git", "-C", str(Path(args.bin).resolve().parent), "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    Path(args.out).write_text(
        json.dumps(
            {
                "source": "engine",
                "genre": args.genre,
                "engine": sha,
                "window": args.window,
                "codec": args.codec,
                "tracks": tracks,
            },
            indent=1,
        )
    )
    print(
        f"swept {len(wavs)} seeds: render {rendered - started:.0f} s, measure {time.time() - rendered:.0f} s "
        f"-> {args.out}",
        file=sys.stderr,
    )
    return 0


def _table(profile: dict) -> dict[str, np.ndarray]:
    rows = list(profile["tracks"].values())
    keys = sorted({k for r in rows for k in r})
    return {k: np.array([r[k] for r in rows if k in r and np.isfinite(r[k])]) for k in keys}


def gap_rows(ref: dict, ours: dict) -> list[dict]:
    r, o = _table(ref), _table(ours)
    rows = []
    for key in sorted(set(r) & set(o)):
        rp10, rp50, rp90 = np.percentile(r[key], [10, 50, 90])
        op10, op50, op90 = np.percentile(o[key], [10, 50, 90])
        spread = max(rp90 - rp10, 1e-9)
        if key in INFO_ONLY:
            status = "info"
        elif rp10 <= op50 <= rp90:
            status = "green"
        elif rp10 - 0.5 * spread <= op50 <= rp90 + 0.5 * spread:
            status = "amber"
        else:
            status = "red"
        rows.append(
            {
                "property": key,
                "ref": [rp10, rp50, rp90],
                "ours": [op10, op50, op90],
                "status": status,
                "distance": float(abs(op50 - rp50) / spread),
            }
        )
    return rows


def cmd_gap(args: argparse.Namespace) -> int:
    ref, ours = json.loads(Path(args.ref).read_text()), json.loads(Path(args.ours).read_text())
    rows = gap_rows(ref, ours)
    mark = {"green": "  ok ", "amber": " ~~  ", "red": " RED ", "info": " info"}
    print(f"{'property':28} {'reference p10 / p50 / p90':>30}   {'ours p10 / p50 / p90':>30}  status  dist")
    for row in sorted(rows, key=lambda x: (x["status"] != "red", -x["distance"])):
        f = lambda v: f"{v[0]:9.3g} {v[1]:9.3g} {v[2]:9.3g}"
        print(
            f"{row['property']:28} {f(row['ref']):>30}   {f(row['ours']):>30}  {mark[row['status']]}  "
            f"{row['distance']:.2f}"
        )
    counts = {s: sum(r["status"] == s for r in rows) for s in ("red", "amber", "green")}
    score = sum(r["distance"] for r in rows if r["status"] != "info")
    print(
        f"\nred {counts['red']}  amber {counts['amber']}  green {counts['green']}  distance sum {score:.2f}  "
        f"(ref n={len(ref['tracks'])}, ours n={len(ours['tracks'])})"
    )
    if args.trend:
        with open(args.trend, "a") as fh:
            fh.write(
                json.dumps(
                    {
                        "label": args.label,
                        "time": time.time(),
                        "engine": ours.get("engine"),
                        **counts,
                        "distance": score,
                    }
                )
                + "\n"
            )
    return 0


def validate_rows(anchor: dict, corpus: dict) -> tuple[dict, list[dict]]:
    """Merge a model corpus into an anchor profile, property by property.

    The corpus is a reference only where it agrees with the anchors: a property whose corpus p50 sits inside the
    anchor p10-p90 takes both sets' values; otherwise the anchor wins and the corpus values for it are dropped.
    """
    a, c = _table(anchor), _table(corpus)
    decisions = []
    kept: set[str] = set()
    for key in sorted(set(a) & set(c)):
        lo, hi = np.percentile(a[key], [10, 90])
        mid = float(np.percentile(c[key], 50))
        ok = bool(lo <= mid <= hi)
        decisions.append({"property": key, "anchor": [float(lo), float(hi)], "corpus_p50": mid, "kept": ok})
        if ok:
            kept.add(key)
    tracks = dict(anchor["tracks"])
    for path, feats in corpus["tracks"].items():
        tracks[path] = {k: v for k, v in feats.items() if k in kept}
    merged = {"source": "anchor+corpus", "anchors": len(anchor["tracks"]), "corpus": len(corpus["tracks"])}
    return {**merged, "kept_properties": sorted(kept), "tracks": tracks}, decisions


def cmd_validate(args: argparse.Namespace) -> int:
    anchor, corpus = json.loads(Path(args.anchor).read_text()), json.loads(Path(args.corpus).read_text())
    merged, decisions = validate_rows(anchor, corpus)
    for d in decisions:
        mark = "keep" if d["kept"] else "DROP"
        print(
            f"{d['property']:28} anchor {d['anchor'][0]:9.3g} .. {d['anchor'][1]:9.3g}  corpus p50 {d['corpus_p50']:9.3g}  {mark}"
        )
    kept = sum(d["kept"] for d in decisions)
    print(f"\ncorpus agrees with the anchors on {kept} of {len(decisions)} properties -> {args.out}")
    Path(args.out).write_text(json.dumps(merged, indent=1))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    ours = str(Path(args.dir) / f"{args.genre}.json")
    sweep = argparse.Namespace(**{**vars(args), "out": ours})
    if cmd_sweep(sweep):
        return 1
    return cmd_gap(argparse.Namespace(ref=args.ref, ours=ours, trend=args.trend, label=args.label))


def _clip(job: tuple[str, str, str | None, float, float]) -> None:
    """Cut, loudness-match and fade one clip, written as 320k MP3."""
    import pyloudnorm
    import soundfile as sf

    source, out, window, seconds, target = job
    offset, _ = _window(source, window)
    stereo, sr = _load(source, f"{offset}:{seconds}")
    gain = 10 ** ((target - pyloudnorm.Meter(sr).integrated_loudness(stereo)) / 20)
    stereo = stereo * gain
    peak = float(np.max(np.abs(stereo)))
    if peak > 0.98:
        stereo *= 0.98 / peak
    fade = np.linspace(0, 1, int(0.5 * sr))[:, None]
    stereo[: len(fade)] *= fade
    stereo[-len(fade) :] *= fade[::-1]
    wav = out[: -len(".mp3")] + ".wav"
    sf.write(wav, stereo, sr)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-c:a", "libmp3lame", "-b:a", "320k", out], check=True)
    os.remove(wav)


def cmd_listen(args: argparse.Namespace) -> int:
    """A blind kit: shuffled, loudness-matched clips with hidden sources, a scoresheet, a page and a sealed key."""
    import random

    groups = {"engine": (args.engine, args.engine_window), "model": (args.model, "35%"), "anchor": (args.anchor, "35%")}
    items = [(group, path, window) for group, (paths, window) in groups.items() for path in paths or []]
    random.Random(args.seed).shuffle(items)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    key, jobs = [], []
    for n, (group, path, window) in enumerate(items, 1):
        name = f"clip-{n:02d}.mp3"
        key.append({"clip": name, "group": group, "source": path})
        jobs.append((path, str(out / name), window, args.seconds, args.lufs))
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(_clip, jobs))
    (out / ".key.json").write_text(json.dumps(key, indent=1))
    rows = "\n".join(f"| {k['clip']} | | |" for k in key)
    (out / "scoresheet.md").write_text(
        "# Blind listen\n\nFor each clip: keep or skip, and any tell that says it was made by code.\n\n"
        f"| Clip | Keep? | Tell |\n|---|---|---|\n{rows}\n\nReveal: `cat .key.json` after scoring.\n"
    )
    players = "\n".join(
        f'<li><b>{k["clip"][:-4]}</b><br><audio controls preload="none" src="{k["clip"]}"></audio></li>' for k in key
    )
    (out / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Blind listen</title>"
        "<style>body{font:16px system-ui;margin:24px;max-width:640px}li{margin:14px 0}audio{width:100%}</style>"
        f"<h1>Blind listen</h1><p>{len(key)} clips, {args.seconds:.0f} s each, loudness-matched to "
        f"{args.lufs:.0f} LUFS. Sources are hidden.</p><ol style='list-style:none;padding:0'>{players}</ol>"
    )
    counts = {g: sum(k["group"] == g for k in key) for g in groups}
    print(f"kit: {len(key)} clips {counts} -> {out} (key sealed in .key.json)")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="record-loop", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("profile")
    a.add_argument("files", nargs="+")
    a.add_argument("--out", required=True)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    # A record's main groove: from a third of the way in, as long as one song-plan drop.
    a.add_argument("--window", default="35%:48")
    a.add_argument("--codec", help="round-trip WAVs through MP3 at this bitrate first, e.g. 320k")
    a.set_defaults(fn=cmd_profile)
    a = sub.add_parser("sweep")
    a.add_argument("--bin", required=True)
    a.add_argument("--genre", required=True)
    a.add_argument("--seeds", default="1-50")
    a.add_argument("--variety", type=float, default=0.75)
    a.add_argument("--dir", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    # The song plan's second drop (136-184 s): the engine's main groove, the same length as a reference window.
    a.add_argument("--window", default="136:48")
    a.add_argument("--codec", default="320k", help="match the references' MP3 encode; pass '' for raw WAV")
    a.set_defaults(fn=cmd_sweep)
    a = sub.add_parser("gap")
    a.add_argument("ref")
    a.add_argument("ours")
    a.add_argument("--trend")
    a.add_argument("--label", default="")
    a.set_defaults(fn=cmd_gap)
    a = sub.add_parser("validate")
    a.add_argument("--anchor", required=True)
    a.add_argument("--corpus", required=True)
    a.add_argument("--out", required=True)
    a.set_defaults(fn=cmd_validate)
    a = sub.add_parser("run")
    a.add_argument("--bin", required=True)
    a.add_argument("--genre", required=True)
    a.add_argument("--ref", required=True)
    a.add_argument("--seeds", default="1-50")
    a.add_argument("--variety", type=float, default=0.75)
    a.add_argument("--dir", required=True)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a.add_argument("--window", default="136:48")
    a.add_argument("--codec", default="320k")
    a.add_argument("--trend")
    a.add_argument("--label", default="")
    a.set_defaults(fn=cmd_run)
    a = sub.add_parser("listen")
    a.add_argument("--out", required=True)
    a.add_argument("--engine", nargs="*")
    a.add_argument("--model", nargs="*")
    a.add_argument("--anchor", nargs="*")
    # Inside the song plan's second drop, like the gap window.
    a.add_argument("--engine-window", default="137")
    a.add_argument("--seconds", type=float, default=45)
    a.add_argument("--lufs", type=float, default=-16)
    a.add_argument("--seed", type=int, default=20261007)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a.set_defaults(fn=cmd_listen)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
