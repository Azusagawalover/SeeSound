"""Fixed official split, real WAV-to-feature provenance and public package checks."""
import csv
import hashlib
import json
from pathlib import Path
import unittest

import numpy as np

from prepare_esc50 import COMMIT, features, read_audio, select_rows
from train_esc50 import encode_mel, load_public

ROOT = Path(__file__).resolve().parent.parent


class PublicDataChecks(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((ROOT / "Resources/ESC50-Catalog.json").read_text())
        self.report = json.loads((ROOT / "Training/Results/ESC50-Report.json").read_text())

    def test_official_fold_selection_is_balanced_and_disjoint(self):
        with (ROOT / "References/ESC50/esc50.upstream.csv").open() as file:
            rows = select_rows(list(csv.DictReader(file)))
        self.assertEqual(len(rows), 120)
        train = {row["filename"] for row in rows if row["fold"] != "5"}
        test = {row["filename"] for row in rows if row["fold"] == "5"}
        self.assertEqual(len(train), 96); self.assertEqual(len(test), 24)
        self.assertEqual(train, set(self.report["trainIDs"]))
        self.assertEqual(test, set(self.report["testIDs"]))
        self.assertTrue(train.isdisjoint(test))
        for fold in range(1, 6):
            self.assertEqual(sum(int(row["fold"]) == fold for row in rows), 24)

    def test_all_bundled_test_audio_matches_source_checksums(self):
        self.assertEqual(self.catalog["commit"], COMMIT)
        for clip in self.catalog["clips"]:
            data = (ROOT / "Resources/PublicAudio" / clip["id"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), clip["sha256"])
            self.assertEqual(clip["fold"], 5)
            self.assertIn(clip["sourceFile"], clip["attribution"])

    def test_bundled_spectra_are_recomputed_from_the_actual_recording(self):
        clip = self.catalog["clips"][0]
        audio, rate = read_audio(ROOT / "Resources/PublicAudio" / clip["id"])
        spectrum, waveform = features(audio, rate)
        np.testing.assert_allclose(spectrum, clip["features"], rtol=0, atol=1e-12)
        np.testing.assert_allclose(waveform, clip["waveform"], rtol=0, atol=1e-12)
        model = json.loads((ROOT / "Resources/ESC50-Model.json").read_text())
        self.assertEqual(encode_mel(spectrum), model["testInput"])

    def test_silent_signal_remains_finite_and_malformed_features_are_rejected(self):
        spectrum, waveform = features(np.zeros(5 * 44100), 44100)
        self.assertTrue(np.isfinite(spectrum).all())
        self.assertEqual(float(np.max(spectrum)), 0)
        self.assertEqual(max(waveform), 0)
        with self.assertRaises(ValueError):
            encode_mel([[0.0]])
        spectrum[0][0] = float("nan")
        with self.assertRaises(ValueError):
            encode_mel(spectrum)

    def test_report_identifies_a_subset_and_matches_the_packaged_weights(self):
        model_data = (ROOT / "Resources/ESC50-Model.json").read_bytes()
        self.assertEqual(hashlib.sha256(model_data).hexdigest(), self.report["modelSHA256"])
        self.assertEqual(self.report["kind"], "public-dataset-holdout")
        self.assertEqual(self.report["dataset"]["testFolds"], [5])
        self.assertEqual(self.report["evaluation"]["testCount"], 24)
        self.assertTrue(self.report["limitations"])


if __name__ == "__main__":
    unittest.main()
