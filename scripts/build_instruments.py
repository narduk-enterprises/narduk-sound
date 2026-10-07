#!/usr/bin/env python3
"""Builds Sources/NardukMusicDSP/Resources/instruments.bin: the recorded instruments behind the sampled keys and
percussion voices (`KeysVoice.sampledPiano` ... `sampledNylonGuitar`, `PercussionVoice`).

Sources (see Resources/LICENSES/Instruments.md): Salamander Grand Piano V3 (CC BY 3.0), jSteelDrum v2 (Unlicense),
VSCO 2 Community Edition and the Versilian Community Sample Library (CC0), the University of Iowa Musical Instrument
Samples ("without restrictions") and one Freesound snap (CC0). `instruments_fetch.py` pulls them into
~/.cache/narduk-sound/instruments; they are never committed. The snap needs a Freesound login, so it is fetched by
hand into the same cache (freesound/532862__joma86__fingersnap.wav).

Every clip is resampled to 32 kHz mono 16-bit. Plucked and struck notes are one-shots trimmed to their first seconds
with a faded tail; the flute and the sax hold on a loop with a crossfade baked into its end. Roots sit a minor third
apart, so playback never shifts a recording by more than a tone and a half. Needs ffmpeg (decoding FLAC and AIFF).

    python3 scripts/instruments_fetch.py
    python3 scripts/build_instruments.py
"""
import json, os, struct, subprocess, sys
import numpy as np
from scipy.signal import butter, sosfiltfilt

CACHE = os.path.expanduser("~/.cache/narduk-sound/instruments")
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "NardukMusicDSP", "Resources", "instruments.bin")
SR = 32000
NOTES = {"C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8,
         "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11}


def midi(name):
    """'D#4' -> 63 (C4 = 60)."""
    return 12 * (int(name[-1]) + 1) + NOTES[name[:-1]]


def load(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    # Below 40 Hz there is only rumble: the guitar recordings carry sub-20 Hz thumps between notes.
    return sosfiltfilt(butter(4, 40, "highpass", fs=SR, output="sos"), x)


def envelope(x, ms=5):
    n = max(int(ms / 1000 * SR), 1)
    return np.sqrt(np.convolve(x * x, np.ones(n) / n, "same"))


def onset(x, threshold=0.08, pre=0.002):
    """The first sample where the envelope passes `threshold` of its peak, less a short pre-roll."""
    e = envelope(x, 2)
    i = int(np.argmax(e > threshold * e.max()))
    return max(i - int(pre * SR), 0)


def onsets(x, gap=1.0, threshold=0.06, rise=4.0):
    """Note starts in a recording of separate notes, at least `gap` seconds apart. With `rise`, a start is where the
    envelope jumps that many times above where it was 30 ms before (a pluck rings into the next one); without, where
    it passes `threshold` of the peak after falling under half of that (a held note stops before the next)."""
    e = envelope(x, 10)
    hop = int(0.005 * SR)
    h = e[::hop]
    top = e.max()
    starts, last, armed = [], -10 * SR, True
    for i in range(6, len(h) - 4):
        if rise is None:
            if h[i] < 0.5 * threshold * top:
                armed = True
            hit = armed and h[i] > threshold * top
            if hit:
                armed = False
        else:
            hit = h[i + 4] > threshold * top and h[i + 4] > rise * (h[i - 6] + 1e-5)
        if hit and i * hop - last >= gap * SR:
            k = i * hop
            if rise is not None:
                k += int(np.argmax(e[k:k + 8 * hop] > 0.3 * h[i + 4]))
            starts.append(max(k - int(0.004 * SR), 0))
            last = i * hop
    return starts


def f0(x):
    """Pitch (MIDI) of a steady stretch, by autocorrelation."""
    s = x - x.mean()
    n = len(s)
    ac = np.correlate(s, s, "full")[n - 1:]
    a, b = int(SR / 2200), int(SR / 60)
    k = a + int(np.argmax(ac[a:b]))
    return 69 + 12 * np.log2(SR / k / 440)


def fade(x, a=0.001, b=0.05):
    x = x.copy()
    na, nb = max(int(a * SR), 1), max(int(b * SR), 1)
    x[:na] *= np.linspace(0, 1, na)
    x[-nb:] *= np.linspace(1, 0, nb) ** 2
    return x


def level(x, rms, window=0.4):
    """Scales `x` so its first `window` seconds sit at `rms`, the peak kept under 0.95."""
    head = x[:int(window * SR)]
    y = x * (rms / max(np.sqrt((head ** 2).mean()), 1e-6))
    p = np.abs(y).max()
    return y * (0.95 / p) if p > 0.95 else y


def one_shot(x, seconds, tail):
    s = onset(x)
    return fade(x[s:s + int(seconds * SR)], 0.001, tail)


def sustain(x, attack=0.35, shortest=0.45, longest=0.9, xfade=0.06):
    """A held note: its onset and `attack`, then a loop chosen where the recording best repeats itself. Returns
    (clip, loopStart, loopEnd) with the crossfade baked into the loop's last `xfade` seconds."""
    x = x[onset(x):]
    X = int(xfade * SR)
    a = int(attack * SR)
    win = int(0.03 * SR)
    best, best_n = None, None
    for n in range(int(shortest * SR), min(int(longest * SR), len(x) - a - win - 1), 8):
        d = np.mean((x[a:a + win] - x[a + n:a + n + win]) ** 2)
        if best is None or d < best:
            best, best_n = d, n
    n = best_n
    clip = x[:a + n].copy()
    w = np.linspace(0, 1, X, endpoint=False)
    clip[a + n - X:a + n] = x[a + n - X:a + n] * np.cos(w * np.pi / 2) + x[a - X:a] * np.sin(w * np.pi / 2)
    clip[:int(0.001 * SR)] *= np.linspace(0, 1, int(0.001 * SR))
    return clip, a, a + n


def run_notes(x, first, count=12, rise=None):
    """The notes of a chromatic run of `count` notes from MIDI `first`: {pitch: (samples from its onset, measured root)}. Each start is
    named by its measured pitch, so a breath or a squeak between notes is skipped rather than shifting the run."""
    starts = onsets(x, rise=rise)
    notes = {}
    for s in starts:
        seg = x[s:s + int(3 * SR)]
        if len(seg) < int(2 * SR):
            continue
        measured = f0(seg[int(0.3 * SR):int(0.3 * SR) + 4096])
        pitch = int(round(measured))
        if abs(measured - pitch) < 0.5 and first <= pitch < first + count and pitch not in notes:
            notes[pitch] = (seg, round(float(measured), 2))
    missing = [p for p in range(first, first + count) if p not in notes]
    if missing:
        print(f"  missing {missing}", file=sys.stderr)
    return notes


def main():
    clips, pcm, instruments = [], [], []
    offset = 0

    def add(instrument, root, x, loop=None, layer=0, index=0, source=""):
        nonlocal offset
        x = np.clip(x, -1, 1)
        pcm.append((x * 32767).round().astype("<i2").tobytes())
        clips.append(dict(instrument=instrument, root=round(float(root), 3), layer=layer, offset=offset, count=len(x),
                          loopStart=loop[0] if loop else 0, loopEnd=loop[1] if loop else 0, index=index,
                          source=source))
        offset += len(x)

    def cache(*parts):
        return os.path.join(CACHE, *parts)

    # Piano: Salamander's soft (v4) layer, C3 ... A5. Two seconds of each note and a long fade.
    instruments.append(dict(name="piano", velocitySplit=0))
    for o in (3, 4, 5):
        for n in ("C", "D#", "F#", "A"):
            name = f"Samples/{n}{o}v4.flac"
            add("piano", midi(f"{n}{o}"), level(one_shot(load(cache("salamander", f"{n}{o}v4.flac")), 1.8, 0.5), 0.1),
                source=name)

    # Steel drum: jSteelDrum layer 4, C4 ... A5, named at concert pitch.
    instruments.append(dict(name="steelDrum", velocitySplit=0))
    for f in ("060__C4", "063_Eb4", "066_Gb4", "069__A4", "072__C5", "075_Eb5", "078_Gb5", "081__A5"):
        name = f"flac/SteelDrum_{f}_4.flac"
        x = one_shot(load(cache("jsteeldrum", f"SteelDrum_{f}_4.flac")), 1.3, 0.35)
        add("steelDrum", int(f[:3]), level(x, 0.12, 0.25), source=name)

    # Flute: VSCO's sustained vibrato flute. Its file names sit an octave low (C4 sounds C5); the root is measured.
    instruments.append(dict(name="flute", velocitySplit=0))
    for n in ("C4", "E4", "A4", "C5", "E5", "A5", "C6"):
        name = f"Woodwinds/Flute/susvib/LDFlute_susvib_{n}_v1_1.wav"
        x = load(cache("vsco2ce", f"LDFlute_susvib_{n}_v1_1.wav"))
        root = midi(n) + 12
        clip, a, b = sustain(x)
        add("flute", root, level(clip, 0.12, 1.0), (a, b), source=name)

    # Alto sax: Iowa's vibrato runs C4 ... B4, pp (layer 0) and mf (layer 1), a root every minor third.
    instruments.append(dict(name="sax", velocitySplit=0.55))
    for layer, dyn in ((0, "pp"), (1, "mf")):
        name = f"Woodwinds/altosaxophone/AltoSax.Vib.{dyn}.C4B4.aiff"
        notes = run_notes(load(cache("iowa", name)), 60)
        for root in (60, 63, 66, 69, 71):
            seg, measured = notes[root]
            clip, a, b = sustain(seg, attack=0.3)
            add("sax", measured, level(clip, 0.1 if layer == 0 else 0.13, 1.0), (a, b), layer=layer, source=name)

    # Nylon guitar: Iowa's Raimundo classical guitar, plucked on the G string (C4 ... B4) and the B string
    # (C5 ... Gb5).
    instruments.append(dict(name="nylonGuitar", velocitySplit=0))
    for name, first, roots in (("Piano_Other/guitar/Guitar.mf.sulG.C4B4.mono.aif", 60, (60, 63, 66, 69)),
                               ("Piano_Other/guitar/Guitar.mf.sulB.C5Gb5.mono.aif", 72, (72, 75, 78))):
        notes = run_notes(load(cache("iowa", name)), first, 12 if first == 60 else 7, rise=4.0)
        for root in roots:
            seg, measured = notes[root]
            add("nylonGuitar", measured, level(one_shot(seg, 1.8, 0.5), 0.1, 0.3), source=name)

    # Shaker: VCSL's small shaker strokes for soft notes (layer 0) and the large shaker's for the accents (layer 1),
    # played in turn.
    instruments.append(dict(name="shaker", velocitySplit=0.2))
    shakes = [(0, f"Shaker, Small/Mid_ShakerHighFaster_{d}_rr{r}.wav") for r in (1, 2) for d in ("Up", "Down")]
    shakes += [(0, f"Shaker, Small/Mid_ShakerDouble_{d}_rr1.wav") for d in ("Up", "Down")]
    shakes += [(1, "Shaker, Large/LShaker_Shake1U_rr1_Mid.wav"), (1, "Shaker, Large/LShaker_Shake1D_rr2_Mid.wav")]
    for i, (layer, f) in enumerate(shakes):
        name = f"Idiophones/Struck Idiophones/{f}"
        x = one_shot(load(cache("vcsl", name)), 0.4 if layer == 0 else 0.3, 0.06)
        add("shaker", 0, x * (0.5 / np.abs(x).max()), layer=layer, index=i, source=name)

    # Tambourine: VCSL's tambourine 1, a shake for soft notes (layer 0) and a hit for loud ones (layer 1).
    instruments.append(dict(name="tambourine", velocitySplit=0.4))
    for layer, files in ((0, ("Tamb1_Shake_rr1_Mid.wav", "Tamb1_Shake_rr2_Mid.wav")),
                         (1, ("Tamb1_Hit_v1_rr1_Mid.wav", "Tamb1_Hit_v2_rr1_Mid.wav"))):
        for i, f in enumerate(files):
            name = f"Idiophones/Struck Idiophones/Tambourine 1/{f}"
            x = one_shot(load(cache("vcsl", name)), 0.9, 0.2)
            add("tambourine", 0, x * (0.5 / np.abs(x).max()), layer=layer, index=i, source=name)

    # Congas: VCSL's open tones, the low tumba (drum 0) and the conga (drum 1), two takes each. A percussion clip's
    # `root` names its drum.
    instruments.append(dict(name="conga", velocitySplit=0))
    for drum, d in ((0, "Tumba"), (1, "Conga")):
        for r in (1, 2):
            name = f"Membranophones/Struck Membranophones/Conga/{d}_HitN_v2_rr{r}_Sum.wav"
            x = one_shot(load(cache("vcsl", name)), 0.6, 0.15)
            add("conga", drum, x * (0.6 / np.abs(x).max()), index=r - 1, source=name)

    # Finger snaps: four snaps cut from Joma86's take on Freesound.
    instruments.append(dict(name="snap", velocitySplit=0))
    x = load(cache("freesound", "532862__joma86__fingersnap.wav"))
    starts = onsets(x, gap=0.3, threshold=0.2)
    for i, s in enumerate(starts[:4]):
        seg = fade(x[s:s + int(0.3 * SR)], 0.0005, 0.08)
        add("snap", 0, seg * (0.6 / np.abs(seg).max()), index=i, source="532862__joma86__fingersnap.wav")

    manifest = json.dumps(dict(sampleRate=SR, instruments=instruments, clips=clips), separators=(",", ":")).encode()
    with open(OUT, "wb") as f:
        f.write(b"NVS2" + struct.pack("<I", len(manifest)) + manifest + b"".join(pcm))
    seconds = {}
    for c in clips:
        seconds[c["instrument"]] = seconds.get(c["instrument"], 0) + c["count"] / SR
    for name, s in seconds.items():
        print(f"{name:12} {s:5.1f} s  {s * SR * 2 / 1e6:.2f} MB", file=sys.stderr)
    print(f"{len(clips)} clips, {os.path.getsize(OUT) / 1e6:.2f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
