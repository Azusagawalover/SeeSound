"""Data split / encoding checks; these are not acoustic recognition benchmarks."""
import json
from pathlib import Path
import tempfile
import unittest

from train_sound import encode, load_dataset, smoke_samples, split_batches


class TrainingChecks(unittest.TestCase):
    def test_holdout_never_shares_batches(self):
        samples = smoke_samples()
        train, test, labels = split_batches(samples, 2026)
        self.assertTrue(set(train).isdisjoint(test))
        self.assertTrue({samples[i]["batch"] for i in train}.isdisjoint({samples[i]["batch"] for i in test}))
        self.assertEqual(set(labels), {samples[i]["label"] for i in train})
        self.assertEqual(set(labels), {samples[i]["label"] for i in test})
        self.assertEqual((train, test, labels), split_batches(samples, 2026))

    def test_single_batch_is_rejected(self):
        samples = smoke_samples()
        for sample in samples:
            sample["batch"] = samples[0]["batch"]
        with self.assertRaises(ValueError):
            split_batches(samples, 2026)

    def test_delta_encoding_matches_boundary_contract(self):
        values = [[0.0] * 4 for _ in range(64)]
        values[0][0] = 0.08
        encoded = encode(values)
        self.assertEqual(encoded[0], [1, 0, 0, 0, 0, 0, 0, 0])
        self.assertEqual(encoded[1], [0, 1, 0, 0, 0, 0, 0, 0])

    def test_dataset_rejects_duplicate_recordings_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "dataset.json"
            data = {"format": "SeeSoundDataset", "version": 1, "featureSchema": "audio-envelope-v1", "encodingStep": 0.08,
                    "samples": smoke_samples()}
            path.write_text(json.dumps(data))
            self.assertEqual(len(load_dataset(path)), 72)
            data["samples"][1]["fingerprint"] = data["samples"][0]["fingerprint"]
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                load_dataset(path)
            data["samples"] = smoke_samples()
            data["samples"][0]["features"][0][0] = float("nan")
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                load_dataset(path)


if __name__ == "__main__":
    unittest.main()
