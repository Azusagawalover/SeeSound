"""SeeSound experimental audio classifier: snnTorch LIF vs a matched small ANN.

Uses snnTorch 0.9.4 (MIT). See References/SNN/snnTorch-LICENSE.txt.
The app's delta-encoded features are shared by both methods. No audio is uploaded.
--smoke generates explicitly synthetic data solely for checking the tooling.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import uuid

import numpy as np
import snntorch as snn
from snntorch import surrogate
import torch
from torch import nn

LABELS = ["knock", "doorbell", "clapping", "other"]
STEP = 0.08


def encode(features):
    reference = [0.0] * 4
    rows = []
    for frame in features:
        row = [0.0] * 8
        for channel in range(4):
            delta = frame[channel] - reference[channel]
            if delta >= STEP:
                row[channel * 2] = 1.0
                reference[channel] += STEP
            elif delta <= -STEP:
                row[channel * 2 + 1] = 1.0
                reference[channel] -= STEP
        rows.append(row)
    return rows


def load_dataset(path):
    if path.stat().st_size > 5 * 1024 * 1024:
        raise ValueError("Dataset exceeds 5 MB")
    data = json.loads(path.read_text())
    if (data.get("format"), data.get("version"), data.get("featureSchema"), data.get("encodingStep")) != (
        "SeeSoundDataset", 1, "audio-envelope-v1", STEP
    ):
        raise ValueError("Unsupported dataset schema")
    samples = data["samples"]
    if not 2 <= len(samples) <= 100:
        raise ValueError("Expected 2–100 confirmed samples")
    ids, fingerprints = set(), set()
    for sample in samples:
        uuid.UUID(sample["id"])
        uuid.UUID(sample["batch"])
        if sample["id"] in ids or sample["fingerprint"] in fingerprints:
            raise ValueError("Duplicate sample or audio fingerprint")
        ids.add(sample["id"])
        fingerprints.add(sample["fingerprint"])
        if sample["label"] not in LABELS or not 0.5 <= sample["duration"] <= 5:
            raise ValueError("Invalid manual label or duration")
        features = sample["features"]
        if len(features) != 64 or any(len(row) != 4 for row in features):
            raise ValueError("Expected 64 x 4 audio-envelope-v1 features")
        if any(not isinstance(x, (int, float)) or not math.isfinite(x) or not 0 <= x <= 1 for row in features for x in row):
            raise ValueError("Invalid feature value")
    return samples


def split_batches(samples, seed):
    """Pick one reproducible group split with all classes on both sides; never split a batch."""
    labels = sorted({sample["label"] for sample in samples}, key=LABELS.index)
    if len(labels) < 2:
        raise ValueError("Collect at least two classes")
    for label in labels:
        members = [sample for sample in samples if sample["label"] == label]
        if len(members) < 6 or len({sample["batch"] for sample in members}) < 2:
            raise ValueError(f"{label}: collect at least six samples across at least two independent batches")
    batches = sorted({sample["batch"] for sample in samples})
    rng = random.Random(seed)
    count = max(1, round(len(batches) * 0.2))
    # Split candidates depend only on labels / groups and seed, never on model scores.
    candidates = [set(rng.sample(batches, count)) for _ in range(1024)]
    for held in candidates:
        train = [i for i, sample in enumerate(samples) if sample["batch"] not in held]
        test = [i for i, sample in enumerate(samples) if sample["batch"] in held]
        if {samples[i]["label"] for i in train} == set(labels) == {samples[i]["label"] for i in test}:
            return train, test, labels
    raise ValueError("No valid batch-separated split found; collect balanced classes in additional batches")


class SpikingModel(nn.Module):
    def __init__(self, classes, inputs=8, hidden=24):
        super().__init__()
        self.hidden = nn.Linear(inputs, hidden)
        self.neuron = snn.Leaky(beta=0.85, threshold=1.0, reset_delay=False,
                                reset_mechanism="subtract", spike_grad=surrogate.fast_sigmoid(slope=25))
        self.output = nn.Linear(hidden, classes)

    def forward(self, values):
        membrane = values.new_zeros((values.shape[0], self.hidden.out_features))
        scores = []
        for frame in values.unbind(dim=1):
            spikes, membrane = self.neuron(self.hidden(frame), membrane)
            scores.append(self.output(spikes.to(dtype=values.dtype)))
        return torch.stack(scores, dim=1).mean(dim=1)


class OrdinaryModel(nn.Module):
    def __init__(self, classes, inputs=8, hidden=24):
        super().__init__()
        self.hidden = nn.Linear(inputs, hidden)
        self.output = nn.Linear(hidden, classes)

    def forward(self, values):
        return self.output(torch.relu(self.hidden(values))).mean(dim=1)


def parameters(layer):
    return {"weights": layer.weight.detach().tolist(), "bias": layer.bias.detach().tolist()}


def evaluate(model, values, targets, classes):
    model.eval()
    with torch.no_grad():
        logits = model(values)
    predictions = logits.argmax(dim=1)
    matrix = [[0] * classes for _ in range(classes)]
    for actual, predicted in zip(targets.tolist(), predictions.tolist()):
        matrix[actual][predicted] += 1
    return float((predictions == targets).double().mean()), matrix


def smoke_samples():
    rng = random.Random(2026)
    samples = []
    for group in range(3):
        batch = str(uuid.uuid5(uuid.NAMESPACE_URL, f"SeeSound-smoke-batch-{group}")).upper()
        for category, label in enumerate(LABELS):
            for repeat in range(6):
                identifier = f"{group}-{category}-{repeat}"
                features = []
                for frame in range(64):
                    pulse = 0.8 if (frame // (category + 2)) % 2 else 0.1
                    features.append([min(1, max(0, (pulse if channel == category else 0.15) + rng.uniform(-0.03, 0.03))) for channel in range(4)])
                samples.append({"id": str(uuid.uuid5(uuid.NAMESPACE_URL, identifier)).upper(), "batch": batch,
                                "label": label, "duration": 1.0, "features": features,
                                "fingerprint": hashlib.sha256(identifier.encode()).hexdigest()})
    return samples


def train(args):
    if not 1 <= args.epochs <= 500:
        raise ValueError("Epochs must be between 1 and 500")
    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    samples = smoke_samples() if args.smoke else load_dataset(args.dataset)
    train_ids, test_ids, labels = split_batches(samples, args.seed)
    values = torch.tensor([encode(sample["features"]) for sample in samples], dtype=torch.float64)
    targets = torch.tensor([labels.index(sample["label"]) for sample in samples], dtype=torch.long)
    snn_model, ann_model = SpikingModel(len(labels)).double(), OrdinaryModel(len(labels)).double()
    for name, model in [("SNN", snn_model), ("ANN", ann_model)]:
        optimizer = torch.optim.Adam(model.parameters(), lr=0.005)
        model.train()
        for epoch in range(args.epochs):
            order = torch.randperm(len(train_ids)).tolist()
            for begin in range(0, len(order), 16):
                indices = [train_ids[i] for i in order[begin:begin + 16]]
                optimizer.zero_grad()
                loss = nn.functional.cross_entropy(model(values[indices]), targets[indices])
                if not torch.isfinite(loss):
                    raise ValueError("Non-finite training loss")
                loss.backward()
                optimizer.step()
        print(f"{name} trained for {args.epochs} epochs; no test-based checkpoint selection")
    snn_accuracy, snn_matrix = evaluate(snn_model, values[test_ids], targets[test_ids], len(labels))
    ann_accuracy, ann_matrix = evaluate(ann_model, values[test_ids], targets[test_ids], len(labels))
    test_vector = values[test_ids[0]:test_ids[0] + 1]
    with torch.no_grad():
        expected_snn = snn_model(test_vector)[0].tolist()
        expected_ann = ann_model(test_vector)[0].tolist()
    evaluation = {"trainCount": len(train_ids), "testCount": len(test_ids),
                  "trainBatches": sorted({samples[i]["batch"] for i in train_ids}),
                  "testBatches": sorted({samples[i]["batch"] for i in test_ids}),
                  "snnAccuracy": snn_accuracy, "annAccuracy": ann_accuracy,
                  "snnConfusion": snn_matrix, "annConfusion": ann_matrix}
    export = {"format": "SeeSoundExperiment", "version": 1, "featureSchema": "audio-envelope-v1", "encodingStep": STEP,
              "trainingKind": "synthetic-smoke" if args.smoke else "user-samples", "labels": labels,
              "beta": float(snn_model.neuron.beta), "threshold": float(snn_model.neuron.threshold),
              "snnHidden": parameters(snn_model.hidden), "snnOutput": parameters(snn_model.output),
              "annHidden": parameters(ann_model.hidden), "annOutput": parameters(ann_model.output),
              "testInput": test_vector[0].tolist(), "expectedSNN": expected_snn, "expectedANN": expected_ann,
              "evaluation": evaluation}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(export, indent=2, allow_nan=False))
    # Reproducible provenance and exact partition, separate from the portable app model.
    report = {"schema": "SeeSoundTrainingReport/1", "trainingKind": export["trainingKind"], "seed": args.seed,
              "epochs": args.epochs, "torch": torch.__version__, "snntorch": snn.__version__,
              "trainIDs": [samples[i]["id"] for i in train_ids], "testIDs": [samples[i]["id"] for i in test_ids],
              "datasetSHA256": None if args.smoke else hashlib.sha256(args.dataset.read_bytes()).hexdigest(),
              "modelSHA256": hashlib.sha256(args.output.read_bytes()).hexdigest(), "evaluation": evaluation,
              "limitations": "Synthetic smoke data is not evidence of acoustic recognition. No iPhone energy or latency measured."}
    args.output.with_suffix(".report.json").write_text(json.dumps(report, indent=2))
    # Golden scalar trace catches reset / threshold mismatches in the Swift port, including large currents.
    currents = torch.tensor([0.0, 0.4, 0.9, 0.0, 2.5, 0.0, -0.3, 0.8, 0.8, 0.0], dtype=torch.float64)
    neuron = snn.Leaky(beta=0.85, threshold=1.0, reset_delay=False, reset_mechanism="subtract").double()
    membrane = torch.zeros(1, dtype=torch.float64)
    trace = []
    for current in currents:
        spike, membrane = neuron(current.reshape(1), membrane)
        trace.append({"input": float(current), "spike": float(spike), "membrane": float(membrane)})
    args.output.with_suffix(".trace.json").write_text(json.dumps({"beta": float(neuron.beta), "threshold": float(neuron.threshold), "trace": trace}, indent=2))
    print(json.dumps(evaluation, ensure_ascii=False))
    print(f"Saved {args.output}; kind={export['trainingKind']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path, nargs="?")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--smoke", action="store_true", help="Synthetic tooling check; never real recognition evidence")
    options = parser.parse_args()
    if not options.smoke and options.dataset is None:
        parser.error("Provide an exported dataset, or explicitly use --smoke")
    train(options)
