#!/usr/bin/env python3
"""Fetches the source recordings behind Resources/instruments.bin into ~/.cache/narduk-sound/instruments.

Exactly the files listed here, from the sources named in Resources/LICENSES/manifest.json; nothing is fetched twice.
The recordings never go into git: only the packed bank and the licence files do. Every source is free to use and
asks for nothing or only a credit (CC0, the Unlicense, CC BY 3.0, the University of Iowa's "without restrictions").
The finger snap comes from Freesound, which needs a signed-in account, so it is fetched by hand (see below).

    python3 scripts/instruments_fetch.py
    python3 scripts/build_instruments.py
"""
import os, sys, urllib.parse, urllib.request

CACHE = os.path.expanduser("~/.cache/narduk-sound/instruments")
GITHUB = "https://raw.githubusercontent.com"
IOWA = "https://theremin.music.uiowa.edu"

SOURCES = {
    # Salamander Grand Piano V3 by Alexander Holm (CC BY 3.0): the soft v4 layer, a root every minor third.
    "salamander": (f"{GITHUB}/sfzinstruments/SalamanderGrandPiano/master/Samples",
                   [f"{n}{o}v4.flac" for o in (3, 4, 5) for n in ("C", "D#", "F#", "A")]),
    # jSteelDrum v2 by Jeff Learman (Unlicense): velocity layer 4, a root every minor third.
    "jsteeldrum": (f"{GITHUB}/jlearman/jlearman.SteelDrum/main/flac",
                   ["SteelDrum_060__C4_4.flac", "SteelDrum_063_Eb4_4.flac", "SteelDrum_066_Gb4_4.flac",
                    "SteelDrum_069__A4_4.flac", "SteelDrum_072__C5_4.flac", "SteelDrum_075_Eb5_4.flac",
                    "SteelDrum_078_Gb5_4.flac", "SteelDrum_081__A5_4.flac"]),
    # VSCO 2 Community Edition (CC0): sustained flute with vibrato.
    "vsco2ce": (f"{GITHUB}/sgossner/VSCO-2-CE/master/Woodwinds/Flute/susvib",
                [f"LDFlute_susvib_{n}_v1_1.wav" for n in ("C4", "E4", "A4", "C5", "E5", "A5", "C6")]),
    # University of Iowa Musical Instrument Samples ("without restrictions"): alto sax with vibrato, nylon guitar.
    "iowa": (f"{IOWA}/sound files/MIS",
             ["Woodwinds/altosaxophone/AltoSax.Vib.mf.C4B4.aiff", "Woodwinds/altosaxophone/AltoSax.Vib.pp.C4B4.aiff",
              "Piano_Other/guitar/Guitar.mf.sulG.C4B4.mono.aif", "Piano_Other/guitar/Guitar.mf.sulB.C5Gb5.mono.aif"]),
    # Versilian Community Sample Library (CC0): small and large shakers, a tambourine and congas.
    "vcsl": (f"{GITHUB}/sgossner/VCSL/master",
             [f"Idiophones/Struck Idiophones/Shaker, Small/Mid_ShakerHighFaster_{d}_rr{r}.wav"
              for d in ("Up", "Down") for r in (1, 2)]
             + [f"Idiophones/Struck Idiophones/Shaker, Small/Mid_ShakerDouble_{d}_rr1.wav" for d in ("Up", "Down")]
             + ["Idiophones/Struck Idiophones/Shaker, Large/LShaker_Shake1U_rr1_Mid.wav",
                "Idiophones/Struck Idiophones/Shaker, Large/LShaker_Shake1D_rr2_Mid.wav"]
             + [f"Idiophones/Struck Idiophones/Tambourine 1/{f}" for f in (
                 "Tamb1_Hit_v1_rr1_Mid.wav", "Tamb1_Hit_v2_rr1_Mid.wav", "Tamb1_Shake_rr1_Mid.wav",
                 "Tamb1_Shake_rr2_Mid.wav")]
             + [f"Membranophones/Struck Membranophones/Conga/{d}_HitN_v2_rr{r}_Sum.wav"
                for d in ("Tumba", "Conga") for r in (1, 2)]),
}


def path(source, name):
    return os.path.join(CACHE, source, name)


def main():
    total = 0
    for source, (base, names) in SOURCES.items():
        for name in names:
            out = path(source, name)
            if not os.path.exists(out):
                os.makedirs(os.path.dirname(out), exist_ok=True)
                url = base.replace(" ", "%20") + "/" + urllib.parse.quote(name)
                with urllib.request.urlopen(url, timeout=120) as r, open(out + ".part", "wb") as f:
                    f.write(r.read())
                os.replace(out + ".part", out)
            size = os.path.getsize(out)
            total += size
            print(f"{size:>10}  {source}/{name}")
    print(f"{total:>10}  total", file=sys.stderr)
    snap = path("freesound", "532862__joma86__fingersnap.wav")
    if not os.path.exists(snap):
        # Freesound serves originals only to a signed-in account: fetch this one by hand.
        print(f"missing {snap}: download https://freesound.org/people/Joma86/sounds/532862/ there", file=sys.stderr)


if __name__ == "__main__":
    main()
