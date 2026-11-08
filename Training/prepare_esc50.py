"""Download a fixed, balanced ESC-50 subset and precompute public-demo features.

Data: Karol J. Piczak, ESC-50, CC BY-NC 3.0; retain upstream per-clip attribution.
No user recording or upload. Files are fetched from the pinned official GitHub repository.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request
import wave

import numpy as np

COMMIT = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ROOT = "https://raw.githubusercontent.com/karolpiczak/ESC-50/" + COMMIT
SCHEMA = "esc50-logmel16-v2"
LABEL_MAP = {"door_wood_knock": "knock", "clapping": "clapping", "keyboard_typing": "other", "vacuum_cleaner": "other"}


def fetch(url, target):
    if target.exists() and target.stat().st_size:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                content = response.read()
            temporary = target.with_suffix(target.suffix + ".part")
            temporary.write_bytes(content)
            temporary.replace(target)
            return
        except Exception:
            if attempt == 3:
                raise
            time.sleep(attempt + 1)


def select_rows(rows):
    """40 examples per mapped class, eight per fold. Others: four keyboard + four vacuum per fold."""
    selected = []
    for category, count in [("door_wood_knock", 8), ("clapping", 8), ("keyboard_typing", 4), ("vacuum_cleaner", 4)]:
        for fold in range(1, 6):
            available = sorted([row for row in rows if row["category"] == category and int(row["fold"]) == fold], key=lambda row: row["filename"])
            if len(available) < count:
                raise ValueError("Unexpected ESC-50 category / fold counts")
            selected.extend(available[:count])
    train_sources = {row["src_file"] for row in selected if int(row["fold"]) != 5}
    test_sources = {row["src_file"] for row in selected if int(row["fold"]) == 5}
    if train_sources & test_sources:
        raise ValueError("Source recording crosses the train / test boundary")
    return selected


def read_audio(path):
    with wave.open(str(path), "rb") as source:
        if source.getsampwidth() != 2 or source.getnchannels() != 1:
            raise ValueError("Expected official mono PCM16 WAV")
        rate = source.getframerate()
        audio = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float64) / 32768
    if rate != 44100 or len(audio) != 5 * rate:
        raise ValueError("Unexpected official audio format or duration")
    return audio, rate


def features(audio, rate):
    """64 centered Hann-window spectra, FFT=4096, 16 triangular Mel filters, 80–8000 Hz.

    Relative power is clipped to [-80, 0] dB w.r.t. each clip's maximum Mel power, then mapped to [0, 1].
    This is a fixed offline representation, not a calibrated loudness measurement.
    """
    fft_size = 4096
    mel = lambda hz: 2595 * np.log10(1 + np.asarray(hz) / 700)
    hz = lambda value: 700 * (10 ** (np.asarray(value) / 2595) - 1)
    edges = hz(np.linspace(mel(80), mel(8000), 18))
    frequencies = np.fft.rfftfreq(fft_size, 1 / rate)
    bank = np.stack([np.maximum(0, np.minimum((frequencies - edges[i]) / (edges[i + 1] - edges[i]),
                                             (edges[i + 2] - frequencies) / (edges[i + 2] - edges[i + 1]))) for i in range(16)])
    window = np.hanning(fft_size)
    powers, waveform = [], []
    padded = np.pad(audio, (fft_size // 2, fft_size // 2))
    for frame in range(64):
        center = int((frame + 0.5) * len(audio) / 64)
        segment = padded[center:center + fft_size]
        power = np.abs(np.fft.rfft(segment * window)) ** 2
        powers.append(bank @ power)
        chunk = audio[frame * len(audio) // 64:(frame + 1) * len(audio) // 64]
        waveform.append(float(np.sqrt(np.mean(chunk ** 2))))
    powers = np.asarray(powers)
    maximum = max(1e-12, float(powers.max()))
    normalized = np.clip((10 * np.log10(np.maximum(powers / maximum, 1e-8)) + 80) / 80, 0, 1)
    return normalized.tolist(), waveform


def prepare(destination):
    fetch(ROOT + "/meta/esc50.csv", destination / "esc50.csv")
    fetch(ROOT + "/LICENSE", destination / "LICENSE.upstream.txt")
    rows = list(csv.DictReader(io.StringIO((destination / "esc50.csv").read_text())))
    selected = select_rows(rows)
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda row: fetch(ROOT + "/audio/" + row["filename"], destination / "audio" / row["filename"]), selected))
    clips = []
    for row in selected:
        path = destination / "audio" / row["filename"]
        audio, rate = read_audio(path)
        spectrum, waveform = features(audio, rate)
        clips.append({"id": row["filename"], "label": LABEL_MAP[row["category"]], "category": row["category"],
                      "fold": int(row["fold"]), "sourceFile": row["src_file"], "duration": 5.0,
                      "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "features": spectrum, "waveform": waveform})
    hashes = [clip["sha256"] for clip in clips]
    if len(set(hashes)) != len(hashes):
        raise ValueError("Duplicate original audio in selected data")
    data = {"format": "SeeSoundESC50", "version": 1, "commit": COMMIT, "featureSchema": SCHEMA,
            "encodingStep": 0.08, "trainFolds": [1, 2, 3, 4], "testFolds": [5],
            "otherCategories": ["keyboard_typing", "vacuum_cleaner"], "clips": clips}
    (destination / "features.json").write_text(json.dumps(data, separators=(",", ":"), allow_nan=False))
    manifest = {"repository": "https://github.com/karolpiczak/ESC-50", "commit": COMMIT,
                "license": "CC BY-NC 3.0 with upstream per-clip attribution", "testFold": 5,
                "selection": "All 40 knock + all 40 clapping; four keyboard + four vacuum per fold (40 other total).",
                "clips": [{key: value for key, value in clip.items() if key not in ["features", "waveform"]} for clip in clips]}
    (destination / "selection.json").write_text(json.dumps(manifest, indent=2))
    print(f"Prepared {len(clips)} clips: 96 train / 24 held-out test; fixed official folds, no user audio.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    prepare(parser.parse_args().destination)
