"""record-loop: profile references, sweep engine renders, print the gap.

    record-loop profile --out ref.json FILE...             measure audio files (mp3, wav, flac)
    record-loop sweep --bin narduk-music --genre house --seeds 1-50 --dir renders/ --out ours.json
    record-loop gap ref.json ours.json [--trend trend.jsonl --label pass-3]

A profile is {"tracks": {path: {property: value}}, "source": ...}. Measurements are cached next to each audio file
(<file>.features.json, keyed by size and mtime), so re-profiling a reference set is free.
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

# Properties a level decision sets rather than the sound (the engine's -17.5 LUFS trim, Logan 2026-10-07): reported,
# never coloured.
INFO_ONLY = {"lufs", "clipped_ratio"}


def _load(path: str) -> tuple[np.ndarray, int]:
    import librosa

    y, sr = librosa.load(path, sr=None, mono=False)
    y = np.atleast_2d(y)
    if y.shape[0] == 1:
        y = np.vstack([y, y])
    return y.T.astype(np.float64), int(sr)


def measure(path: str) -> dict[str, float]:
    cache = Path(path + ".features.json")
    st = os.stat(path)
    key = f"{st.st_size}:{int(st.st_mtime)}:v1"
    if cache.exists():
        cached = json.loads(cache.read_text())
        if cached.get("key") == key:
            return cached["features"]
    stereo, sr = _load(path)
    feats = features.all_features(stereo, sr)
    cache.write_text(json.dumps({"key": key, "features": feats}))
    return feats


def _profile(paths: list[str], jobs: int) -> dict[str, dict[str, float]]:
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        return dict(zip(paths, pool.map(measure, paths)))


def cmd_profile(args: argparse.Namespace) -> int:
    paths = sorted(str(Path(p)) for p in args.files)
    tracks = _profile(paths, args.jobs)
    Path(args.out).write_text(json.dumps({"source": "files", "tracks": tracks}, indent=1))
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
    tracks = _profile(wavs, args.jobs)
    sha = subprocess.run(
        ["git", "-C", str(Path(args.bin).resolve().parent), "rev-parse", "--short", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    Path(args.out).write_text(
        json.dumps({"source": "engine", "genre": args.genre, "engine": sha, "tracks": tracks}, indent=1)
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


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="record-loop", description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("profile")
    a.add_argument("files", nargs="+")
    a.add_argument("--out", required=True)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a.set_defaults(fn=cmd_profile)
    a = sub.add_parser("sweep")
    a.add_argument("--bin", required=True)
    a.add_argument("--genre", required=True)
    a.add_argument("--seeds", default="1-50")
    a.add_argument("--variety", type=float, default=0.75)
    a.add_argument("--dir", required=True)
    a.add_argument("--out", required=True)
    a.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    a.set_defaults(fn=cmd_sweep)
    a = sub.add_parser("gap")
    a.add_argument("ref")
    a.add_argument("ours")
    a.add_argument("--trend")
    a.add_argument("--label", default="")
    a.set_defaults(fn=cmd_gap)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
