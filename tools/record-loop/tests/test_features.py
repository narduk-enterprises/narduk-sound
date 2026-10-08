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
