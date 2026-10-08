import numpy as np

from record_loop import cli, features


def tone(freq: float, seconds: float = 4.0, sr: int = 48_000) -> np.ndarray:
    t = np.arange(int(seconds * sr)) / sr
    mono = 0.3 * np.sin(2 * np.pi * freq * t)
    return np.stack([mono, mono], axis=1)


def test_band_energy_lands_in_its_band() -> None:
    bass = features.spectrum(tone(100), 48_000)
    assert bass["band_bass_db"] > -0.5
    assert bass["band_presence_db"] < -30


def test_mono_has_no_width_and_clipping_counts() -> None:
    assert features.stereo_width(tone(1000), 48_000)["width_mid_ratio"] < 1e-6
    loud = np.clip(tone(200) * 10, -1, 1)
    assert features.loudness(loud, 48_000)["clipped_ratio"] > 0.1


def test_gap_colours_by_reference_band() -> None:
    ref = {"tracks": {str(i): {"x": float(i), "lufs": -8.0} for i in range(11)}}
    inside = {"tracks": {"a": {"x": 5.0, "lufs": -17.0}}}
    far = {"tracks": {"a": {"x": 50.0, "lufs": -17.0}}}
    assert {r["property"]: r["status"] for r in cli.gap_rows(ref, inside)} == {"x": "green", "lufs": "info"}
    assert {r["property"]: r["status"] for r in cli.gap_rows(ref, far)}["x"] == "red"


def _club_loop(seconds: float, bpm: float, dip_db: float, sr: int = 22050) -> np.ndarray:
    """Kick clicks on every beat over band noise that ducks by dip_db after each kick (a sidechained pad)."""
    rng = np.random.default_rng(1)
    t = np.arange(int(seconds * sr)) / sr
    phase = (t * bpm / 60) % 1
    duck = 10 ** (-dip_db / 20 * np.exp(-phase / 0.15))
    pad = rng.standard_normal(len(t)) * 0.1 * duck
    kick = np.sin(2 * np.pi * 55 * t) * np.exp(-phase * 30) * 0.8
    mono = pad + kick
    return np.column_stack([mono, mono])


def test_pump_depth_moves_with_the_sidechain_at_an_off_grid_tempo() -> None:
    # 124.3 BPM is between librosa's tempo grid steps; a one-tempo fold would smear this dip flat.
    sr = 22050
    flat = features.rhythm(_club_loop(48, 124.3, 0.0), sr)["pump_depth_db"]
    pumped = features.rhythm(_club_loop(48, 124.3, 9.0), sr)["pump_depth_db"]
    assert flat < 1.5
    assert pumped > 3.0


def _melody(seconds: float, seed: int, sr: int = 22050) -> np.ndarray:
    """A random sine note every 0.75 s: tonal content that changes, unlike stationary noise."""
    rng = np.random.default_rng(seed)
    step = int(0.75 * sr)
    notes = [
        np.sin(2 * np.pi * 220 * 2 ** (rng.integers(0, 24) / 12) * np.arange(step) / sr) * 0.3
        for _ in range(int(seconds / 0.75))
    ]
    mono = np.concatenate(notes)
    return np.column_stack([mono, mono])


def test_repetition_rises_when_a_clip_is_looped() -> None:
    sr = 22050
    once = features.structure(_melody(48, 2), sr)["repetition_ratio"]
    looped = features.structure(np.vstack([_melody(12, 3)] * 4), sr)["repetition_ratio"]
    assert looped > once + 0.2
