# Recorded instruments

The recordings behind `instruments.bin` (`KeysVoice.sampledPiano` ...
`sampledConga` and `PercussionVoice`) come from six free sources. Every one is
free to use and asks for nothing or only a credit. The source files are never
stored in this repository: `scripts/instruments_fetch.py` fetches them into
`~/.cache/narduk-sound/instruments` and `scripts/build_instruments.py` builds
the bank from that cache.

## Credits an app shows

`InstrumentBank.credits` returns these lines. Only the first is required by its
licence; the others are courtesy credits (VSCO's readme asks for one).

- "Piano samples from Salamander Grand Piano V3 by Alexander Holm (CC BY 3.0),
  modified."
- "Flute samples from VSCO 2 Community Edition by Versilian Studios / Sam
  Gossner (CC0)."
- "Shaker, tambourine and conga samples from the Versilian Community Sample
  Library (CC0)."
- "Alto sax and nylon guitar samples from the University of Iowa Electronic
  Music Studios."
- "Steel drum samples from jSteelDrum by Jeff Learman (Unlicense)."
- "Finger snap by Joma86 on Freesound (CC0)."

## Changes made to the recordings

Every file was decoded, mixed to mono (the steel drum's two channels are
averaged), high-passed at 40 Hz, resampled to 32 kHz, level-matched and packed
as 16-bit PCM into one file. Plucked and struck notes (piano, steel drum,
guitar) were cut to their first 1.3 to 1.8 seconds with a faded tail. The flute
and sax notes were given loop points with a 60 ms crossfade baked into the loop
end. The Iowa sax and guitar recordings are chromatic runs: single notes were cut
from them and named by their measured pitch. Percussion hits were trimmed and
faded, and four snaps were cut from the one Freesound take. At playback, notes
are pitch-shifted by at most a tone and a half from the nearest recorded note.

## Sources

### Salamander Grand Piano V3

- **Author:** Alexander Holm
- **Source:** https://github.com/sfzinstruments/SalamanderGrandPiano
- **Licence:** Creative Commons Attribution 3.0 Unported (CC BY 3.0),
  https://creativecommons.org/licenses/by/3.0/. Full text:
  `Salamander-CC-BY-3.0.txt` (the repository's `LICENSE`).
- **Licence statement (README):** "This work is licensed under a Creative
  Commons Attribution 3.0 Unported License."
- **Files:** `Samples/{C,D#,F#,A}{3,4,5}v4.flac`, 12 files (the soft v4 layer,
  C3 ... A5).

### jSteelDrum v2

- **Author:** Jeff Learman
- **Source:** https://github.com/jlearman/jlearman.SteelDrum
- **Licence:** the Unlicense (public domain dedication), https://unlicense.org.
  Full text: `jSteelDrum-Unlicense.txt` (the repository's `LICENSE`).
- **Files:** `flac/SteelDrum_{060__C4,063_Eb4,066_Gb4,069__A4,072__C5,075_Eb5,078_Gb5,081__A5}_4.flac`,
  8 files (velocity layer 4).

### VSCO 2 Community Edition

- **Author:** Versilian Studios (Sam Gossner)
- **Source:** https://github.com/sgossner/VSCO-2-CE
- **Licence:** CC0 1.0 Universal,
  https://creativecommons.org/publicdomain/zero/1.0/. Full text:
  `VSCO-2-CE-CC0-1.0.txt` (the repository's `LICENSE`).
- **Requests (Readme.txt, not licence terms):** "do not sell the samples
  directly"; "provide credit to Versilian Studios/Sam Gossner". The samples are
  not sold on their own here, and the credit is in `InstrumentBank.credits`.
- **Files:** `Woodwinds/Flute/susvib/LDFlute_susvib_{C4,E4,A4,C5,E5,A5,C6}_v1_1.wav`,
  7 files.

### Versilian Community Sample Library (VCSL)

- **Author:** Versilian Studios (Sam Gossner)
- **Source:** https://github.com/sgossner/VCSL
- **Licence:** CC0 1.0 Universal,
  https://creativecommons.org/publicdomain/zero/1.0/. Full text:
  `VCSL-CC0-1.0.txt` (the repository's `LICENSE`).
- **Licence statement (README):** "no royalties, no credit, no special terms".
- **Files (18):**
  - `Idiophones/Struck Idiophones/Shaker, Small/Mid_ShakerHighFaster_{Up,Down}_rr{1,2}.wav`,
    `Mid_ShakerDouble_{Up,Down}_rr1.wav`
  - `Idiophones/Struck Idiophones/Shaker, Large/LShaker_Shake1U_rr1_Mid.wav`,
    `LShaker_Shake1D_rr2_Mid.wav`
  - `Idiophones/Struck Idiophones/Tambourine 1/Tamb1_Hit_v{1,2}_rr1_Mid.wav`,
    `Tamb1_Shake_rr{1,2}_Mid.wav`
  - `Membranophones/Struck Membranophones/Conga/{Tumba,Conga}_HitN_v2_rr{1,2}_Sum.wav`

### University of Iowa Musical Instrument Samples

- **Author:** University of Iowa Electronic Music Studios (Lawrence Fritts)
- **Source:** https://theremin.music.uiowa.edu/MIS.html
- **Terms (from that page):** "Since 1997, these recordings have been freely
  available on this website and may be downloaded and used for any projects,
  without restrictions."
- **Files:**
  - `Woodwinds/altosaxophone/AltoSax.Vib.pp.C4B4.aiff`,
    `AltoSax.Vib.mf.C4B4.aiff`
  - `Piano_Other/guitar/Guitar.mf.sulG.C4B4.mono.aif`,
    `Guitar.mf.sulB.C5Gb5.mono.aif`

### Freesound: finger snap

- **Author:** Joma86
- **Source:** https://freesound.org/people/Joma86/sounds/532862/
- **Licence:** Creative Commons 0,
  http://creativecommons.org/publicdomain/zero/1.0/ (the same legal code as
  `VCSL-CC0-1.0.txt`).
- **Files:** `532862__joma86__fingersnap.wav`. Freesound serves originals only
  to a signed-in account, so this file is placed in the cache by hand.
