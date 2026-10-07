#!/usr/bin/env python3
"""Builds Sources/NardukMusicDSP/Resources/vocalsamples.bin from VocalSet (CC BY 4.0, DOI 10.5281/zenodo.1193957).

The result is a few MB of 22.05 kHz mono 16-bit PCM from one female singer (female2): looped sustains of ah/oh/oo/eh/ee
in straight, vibrato and belt techniques at several root pitches, short syllable chops cut from two excerpts, and
three fast scale runs. Changes made to the source: trimmed, downsampled, level-matched, looped with a baked crossfade,
sliced and packed (see Resources/LICENSES/VocalSet.md). The 2.1 GB source is never committed; `vocalset_fetch.py`
pulls single files into ~/.cache/narduk-sound/vocalset.

    python3 scripts/vocalset_fetch.py female2/scales/ female2/excerpts/
    python3 scripts/build_vocal_samples.py
"""
import json, os, struct, sys, wave
import numpy as np
from scipy.signal import resample_poly

CACHE = os.path.expanduser("~/.cache/narduk-sound/vocalset/FULL/female2")
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "NardukMusicDSP", "Resources", "vocalsamples.bin")
SR = 22050
VOWELS = {"ah": "a", "oh": "o", "oo": "u", "eh": "e", "ee": "i"}
TECHNIQUES = ["straight", "vibrato", "belt"]
ROOTS = [62, 65, 68, 71, 74]
LEVEL = 0.2  # RMS of every sustain


def load(path):
    w = wave.open(path)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768
    if w.getnchannels() > 1: x = x.reshape(-1, w.getnchannels()).mean(1)
    assert w.getframerate() == 44100
    return resample_poly(x, 1, 2)


def f0_track(x, hop=0.01, win=0.04, lo=140, hi=1300):
    n = int(win * SR); step = int(hop * SR)
    times, midi = [], []
    for i in range(0, len(x) - n, step):
        s = x[i:i + n] - x[i:i + n].mean()
        e = np.sqrt((s * s).mean())
        m = 0.0
        if e > 0.008:
            ac = np.correlate(s, s, "full")[n - 1:]
            a, b = int(SR / hi), int(SR / lo)
            k = a + int(np.argmax(ac[a:b]))
            if ac[k] > 0.55 * ac[0]:
                if 0 < k < len(ac) - 1:  # parabolic refinement
                    d = ac[k - 1] - 2 * ac[k] + ac[k + 1]
                    if d != 0: k = k + 0.5 * (ac[k - 1] - ac[k + 1]) / d
                m = 69 + 12 * np.log2(SR / k / 440)
        times.append((i + n / 2) / SR); midi.append(m)
    return np.array(times), np.array(midi)


def steady_windows(times, midi, length=0.44, max_spread=0.9, max_jump=0.4):
    """Every `length`-second window of voiced frames whose pitch stays within `max_spread` semitones (the vibrato's
    swing included): (median pitch, spread, start, end) in seconds."""
    n = int(round(length / (times[1] - times[0])))
    out = []
    for i in range(0, len(midi) - n):
        w = midi[i:i + n]
        if (w <= 0).any(): continue
        spread = np.percentile(w, 95) - np.percentile(w, 5)
        if spread <= max_spread and np.abs(np.diff(w)).max() <= max_jump: out.append((float(np.median(w)), float(spread), times[i], times[i + n - 1]))
    return out


def make_loop(x, xfade=0.02):
    """x: a steady note (>= 0.4 s). Returns (clip, loopStart, loopEnd) with a crossfade baked into the loop end."""
    X = int(xfade * SR)
    a = max(int(0.08 * SR), X + 1)
    win = int(0.012 * SR)
    best, bestN = None, None
    for N in range(int(0.16 * SR), min(int(0.36 * SR), len(x) - a - win - 1), 4):
        d = np.mean((x[a:a + win] - x[a + N:a + N + win]) ** 2)
        if best is None or d < best: best, bestN = d, N
    N = bestN
    clip = x[:a + N].copy()
    w = np.linspace(0, 1, X, endpoint=False)
    clip[a + N - X:a + N] = x[a + N - X:a + N] * np.cos(w * np.pi / 2) + x[a - X:a] * np.sin(w * np.pi / 2)
    return clip, a, a + N


def normalise(x, rms=LEVEL):
    r = np.sqrt((x ** 2).mean())
    y = x * (rms / max(r, 1e-6))
    p = np.abs(y).max()
    return y * (0.95 / p) if p > 0.95 else y


def fade(x, a=0.004, b=0.02):
    x = x.copy(); na, nb = int(a * SR), int(b * SR)
    x[:na] *= np.linspace(0, 1, na); x[-nb:] *= np.linspace(1, 0, nb)
    return x


def main():
    clips, pcm = [], []
    offset = 0

    def add(kind, vowel, technique, root, x, loop=None, source="", index=0):
        nonlocal offset
        x = np.clip(x, -1, 1)
        pcm.append((x * 32767).astype("<i2").tobytes())
        c = dict(kind=kind, vowel=vowel, technique=technique, root=round(float(root), 3), offset=offset, count=len(x),
                 loopStart=loop[0] if loop else 0, loopEnd=loop[1] if loop else 0, index=index, source=source)
        clips.append(c); offset += len(x)

    for tech in TECHNIQUES:
        for vowel, letter in VOWELS.items():
            name = f"scales/{tech}/f2_scales_{tech}_{letter}.wav"
            path = os.path.join(CACHE, name)
            if not os.path.exists(path): path = os.path.join(CACHE, f"scales/{tech}/scales_{tech}_{letter}.wav")
            x = load(path)
            t, m = f0_track(x)
            wins = steady_windows(t, m, max_spread=0.9 if tech == "straight" else 2.0, max_jump=0.4 if tech == "straight" else 0.65)
            used = set()
            for root in ROOTS:
                near = [w for w in wins if abs(w[0] - root) < 2.0 and round(w[2], 1) not in used]
                if not near: continue
                f, spread, t0, t1 = min(near, key=lambda w: abs(w[0] - root) + 2 * w[1])
                used.add(round(t0, 1))
                seg = x[int((t0 - 0.02) * SR):int((t1 + 0.02) * SR)]
                clip, ls, le = make_loop(seg)
                add("sustain", vowel, tech, f, normalise(clip), (ls, le), name)
                print(f"{vowel:2} {tech:8} root {root} -> {f:.2f} spread {spread:.2f} loop {le - ls}", file=sys.stderr)

    # Syllable chops: onsets of two excerpts, in both techniques.
    for song in ("row", "dona"):
        for tech in ("straight", "vibrato"):
            name = f"excerpts/{tech}/f2_{song}_{tech}.wav"
            x = load(os.path.join(CACHE, name))
            env = np.sqrt(np.convolve(x * x, np.ones(int(0.01 * SR)) / int(0.01 * SR), "same"))
            hop = int(0.01 * SR)
            e = env[::hop]
            flux = np.maximum(np.diff(np.log(e + 1e-4)), 0)
            peaks = [i for i in range(2, len(flux) - 2) if flux[i] > 0.35 and flux[i] == flux[i - 2:i + 3].max()]
            last = -100; picked = []
            for p in peaks:
                if p - last >= 12 and e[p + 6 if p + 6 < len(e) else p] > 0.02: picked.append(p); last = p
            t, m = f0_track(x)
            for n, p in enumerate(picked[:10]):
                s = max(p * hop - int(0.01 * SR), 0)
                end = min(s + int(0.34 * SR), (picked[n + 1] * hop if n + 1 < len(picked) else len(x)))
                seg = x[s:end]
                if len(seg) < int(0.12 * SR): continue
                voiced = m[(t >= s / SR) & (t <= end / SR)]
                voiced = voiced[voiced > 0]
                root = float(np.median(voiced)) if len(voiced) else 69.0
                add("chop", "ah", tech, root, normalise(fade(seg), 0.2), None, name, index=n)
        print("chops", song, file=sys.stderr)

    # Scale runs.
    for name in ("scales/fast_forte/f2_scales_c_fast_forte_a.wav", "scales/fast_forte/f2_scales_c_fast_forte_o.wav",
                 "scales/fast_piano/f2_scales_c_fast_piano_a.wav"):
        x = load(os.path.join(CACHE, name))
        t, m = f0_track(x)
        voiced = np.where(m > 0)[0]
        s, e = int(max(t[voiced[0]] - 0.03, 0) * SR), int(min(t[voiced[-1]] + 0.05, len(x) / SR) * SR)
        seg = x[s:e]
        root = float(np.median(m[voiced]))
        vowel = {"a": "ah", "o": "oh"}[name.rsplit("_", 1)[1][0]]
        add("run", vowel, "belt" if "forte" in name else "straight", root, normalise(fade(seg), 0.2), None, name)
        print("run", name, round(len(seg) / SR, 2), "s root", round(root, 1), file=sys.stderr)

    manifest = json.dumps(dict(sampleRate=SR, clips=clips), separators=(",", ":")).encode()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(b"NVS1" + struct.pack("<I", len(manifest)) + manifest + b"".join(pcm))
    print(f"{len(clips)} clips, {os.path.getsize(OUT) / 1e6:.2f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
