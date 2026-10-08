"""Per-track sound properties, computed the same way for a reference record and an engine render.

Every function takes a stereo float array shaped (frames, 2) at `sr` and returns plain floats, so a profile is a dict
of numbers that can be compared across sources. Names say the unit: _db, _lufs, _hz, _per_s, _ratio.
"""

from __future__ import annotations

import numpy as np
import pyloudnorm
import scipy.signal as ss

# Bands a mix engineer reads a spectrum in.
BANDS = {
    "sub": (20, 60),
    "bass": (60, 250),
    "lowmid": (250, 500),
    "mid": (500, 2000),
    "presence": (2000, 6000),
    "air": (6000, 16000),
}


def _band_power(mono: np.ndarray, sr: int) -> dict[str, float]:
    f, p = ss.welch(mono, sr, nperseg=8192)
    total = p[(f >= 20) & (f <= 16000)].sum() + 1e-20
    return {name: float(p[(f >= lo) & (f < hi)].sum() / total) for name, (lo, hi) in BANDS.items()}


def loudness(stereo: np.ndarray, sr: int) -> dict[str, float]:
    meter = pyloudnorm.Meter(sr)
    integrated = meter.integrated_loudness(stereo)
    # Short-term loudness (3 s windows, 1 s hop) for range and section contrast.
    win, hop = 3 * sr, sr
    short = []
    for start in range(0, max(1, len(stereo) - win), hop):
        block = stereo[start : start + win]
        rms = np.sqrt(np.mean(block**2)) + 1e-12
        short.append(20 * np.log10(rms))
    short = np.array(short)
    gated = short[short > short.max() - 30] if len(short) else np.array([0.0])
    peak = np.abs(stereo).max() + 1e-12
    rms_all = np.sqrt(np.mean(stereo**2)) + 1e-12
    return {
        "lufs": float(integrated),
        "loudness_range_db": float(np.percentile(gated, 90) - np.percentile(gated, 10)),
        "crest_db": float(20 * np.log10(peak / rms_all)),
        "clipped_ratio": float(np.mean(np.abs(stereo) >= 0.999)),
    }


def spectrum(stereo: np.ndarray, sr: int) -> dict[str, float]:
    mono = stereo.mean(axis=1)
    out = {f"band_{k}_db": float(10 * np.log10(v + 1e-12)) for k, v in _band_power(mono, sr).items()}
    f, _, z = ss.stft(mono, sr, nperseg=4096, noverlap=2048)
    mag = np.abs(z) + 1e-12
    centroid = (f[:, None] * mag).sum(0) / mag.sum(0)
    flatness = np.exp(np.log(mag).mean(0)) / mag.mean(0)
    loud = mag.sum(0) > np.percentile(mag.sum(0), 20)
    out["centroid_hz"] = float(np.median(centroid[loud]))
    out["flatness"] = float(np.median(flatness[loud]))
    return out


def stereo_width(stereo: np.ndarray, sr: int) -> dict[str, float]:
    mid = (stereo[:, 0] + stereo[:, 1]) / 2
    side = (stereo[:, 0] - stereo[:, 1]) / 2
    out = {}
    for name, (lo, hi) in {"low": (20, 250), "mid": (250, 2000), "high": (2000, 16000)}.items():
        sos = ss.butter(4, [lo, hi], btype="band", fs=sr, output="sos")
        m, s = ss.sosfilt(sos, mid), ss.sosfilt(sos, side)
        out[f"width_{name}_ratio"] = float(np.sqrt(np.mean(s**2)) / (np.sqrt(np.mean(m**2)) + 1e-12))
    return out


def rhythm(stereo: np.ndarray, sr: int) -> dict[str, float]:
    import librosa

    mono = librosa.resample(stereo.mean(axis=1), orig_sr=sr, target_sr=22050)
    onset_env = librosa.onset.onset_strength(y=mono, sr=22050)
    tempo, beats = librosa.beat.beat_track(onset_envelope=onset_env, sr=22050, start_bpm=120)
    tempo = float(np.atleast_1d(tempo)[0])
    # House sits at 115-135; fold half/double-time readings into that octave.
    while tempo < 95:
        tempo *= 2
    while tempo > 160:
        tempo /= 2
    onsets = librosa.onset.onset_detect(onset_envelope=onset_env, sr=22050)
    seconds = len(mono) / 22050
    beat_times = librosa.frames_to_time(beats, sr=22050)
    intervals = np.diff(beat_times)
    return {
        "tempo_bpm": tempo,
        "onsets_per_s": float(len(onsets) / seconds),
        "beat_stability_ratio": float(np.std(intervals) / np.mean(intervals)) if len(intervals) > 4 else 1.0,
        **_pump(stereo, sr, tempo),
    }


def _pump(stereo: np.ndarray, sr: int, tempo: float) -> dict[str, float]:
    """Sidechain depth: how far the non-kick low-mid/mid band dips and recovers each beat, averaged over beats."""
    sos = ss.butter(4, [300, 3000], btype="band", fs=sr, output="sos")
    band = ss.sosfilt(sos, stereo.mean(axis=1))
    hop = sr // 200
    env = np.sqrt(ss.decimate(band**2, hop, ftype="fir", zero_phase=True).clip(min=0) + 1e-12)
    beat = 200 * 60 / tempo
    n = int(len(env) // beat)
    if n < 16:
        return {"pump_depth_db": 0.0}
    phase = np.zeros(32)
    counts = np.zeros(32)
    for i in range(int(n * beat)):
        k = int(((i % beat) / beat) * 32)
        phase[k] += env[i]
        counts[k] += 1
    profile = 20 * np.log10(phase / np.maximum(counts, 1) + 1e-12)
    return {"pump_depth_db": float(profile.max() - profile.min())}


def structure(stereo: np.ndarray, sr: int) -> dict[str, float]:
    """Sections from a self-similarity novelty curve; repetition as how much of the track recurs."""
    import librosa

    mono = librosa.resample(stereo.mean(axis=1), orig_sr=sr, target_sr=11025)
    chroma = librosa.feature.chroma_cqt(y=mono, sr=11025, hop_length=2048)
    mfcc = librosa.feature.mfcc(y=mono, sr=11025, hop_length=2048, n_mfcc=13)
    feats = librosa.util.normalize(np.vstack([chroma, mfcc / 50]), axis=0)
    # Beat-ish blocks of ~1.5 s keep the matrix small.
    block = max(1, int(1.5 * 11025 / 2048))
    f = np.array([feats[:, i : i + block].mean(1) for i in range(0, feats.shape[1] - block, block)]).T
    if f.shape[1] < 8:
        return {"sections_per_min": 0.0, "repetition_ratio": 0.0, "chroma_change_per_s": 0.0}
    sim = np.corrcoef(f.T)
    k = 4
    kernel = np.kron(np.array([[1, -1], [-1, 1]]), np.ones((k, k)))
    novelty = np.array(
        [(sim[i - k : i + k, i - k : i + k] * kernel).sum() if k <= i < len(sim) - k else 0 for i in range(len(sim))]
    )
    peaks, _ = ss.find_peaks(novelty, height=np.percentile(novelty, 90), distance=8)
    minutes = len(stereo) / sr / 60
    off_diag = sim[np.triu_indices(len(sim), k=8)]
    dchroma = np.linalg.norm(np.diff(chroma, axis=1), axis=0)
    return {
        "sections_per_min": float(len(peaks) / minutes),
        "repetition_ratio": float(np.mean(off_diag > 0.9)),
        "chroma_change_per_s": float(np.mean(dchroma > 0.5) * 11025 / 2048),
    }


def all_features(stereo: np.ndarray, sr: int) -> dict[str, float]:
    out: dict[str, float] = {}
    for fn in (loudness, spectrum, stereo_width, rhythm, structure):
        out.update(fn(stereo, sr))
    return out
