"""Train a fixed public ESC-50 subset. Fold 5 is held out, never used for model selection."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import shutil
import uuid

import numpy as np
import torch
from torch import nn
import snntorch

from prepare_esc50 import COMMIT, SCHEMA
from train_sound import SpikingModel, OrdinaryModel, parameters, evaluate

LABELS = ["knock", "clapping", "other"]


def encode_mel(features):
    if len(features) != 64 or any(len(row) != 16 for row in features):
        raise ValueError("Expected 64 x 16 Mel features")
    reference = [0.0] * 16
    result = []
    for frame in features:
        row = [0.0] * 32
        for channel in range(16):
            value = frame[channel]
            if not np.isfinite(value) or not 0 <= value <= 1:
                raise ValueError("Invalid Mel features")
            delta = value - reference[channel]
            if delta >= 0.08:
                row[channel * 2] = 1.0
                reference[channel] += 0.08
            elif delta <= -0.08:
                row[channel * 2 + 1] = 1.0
                reference[channel] -= 0.08
        result.append(row)
    return result


def load_public(path):
    data = json.loads(path.read_text())
    if data["format"] != "SeeSoundESC50" or data["commit"] != COMMIT or data["featureSchema"] != SCHEMA:
        raise ValueError("Wrong public dataset provenance")
    clips = data["clips"]
    if len(clips) != 120 or len({clip["id"] for clip in clips}) != 120 or len({clip["sha256"] for clip in clips}) != 120:
        raise ValueError("Unexpected subset size or duplicate recordings")
    for label in LABELS:
        for fold in range(1, 6):
            if sum(clip["label"] == label and clip["fold"] == fold for clip in clips) != 8:
                raise ValueError("Subset must be balanced within each official fold")
    train = [i for i, clip in enumerate(clips) if clip["fold"] in [1, 2, 3, 4]]
    test = [i for i, clip in enumerate(clips) if clip["fold"] == 5]
    if {clips[i]["sourceFile"] for i in train} & {clips[i]["sourceFile"] for i in test}:
        raise ValueError("Source recording leakage")
    return clips, train, test


def train(args):
    if not 1 <= args.epochs <= 500:
        raise ValueError("Epoch count outside supported range")
    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    torch.manual_seed(2026); random.seed(2026); np.random.seed(2026)
    clips, train_ids, test_ids = load_public(args.data / "features.json")
    values = torch.tensor([encode_mel(clip["features"]) for clip in clips], dtype=torch.float64)
    targets = torch.tensor([LABELS.index(clip["label"]) for clip in clips], dtype=torch.long)
    spiking = SpikingModel(3, inputs=32, hidden=48).double()
    ordinary = OrdinaryModel(3, inputs=32, hidden=48).double()
    for name, model in [("SNN", spiking), ("ANN", ordinary)]:
        optimizer = torch.optim.Adam(model.parameters(), lr=0.003)
        model.train()
        for epoch in range(args.epochs):
            order = torch.randperm(len(train_ids)).tolist()
            for begin in range(0, len(order), 16):
                indices = [train_ids[i] for i in order[begin:begin + 16]]
                optimizer.zero_grad()
                loss = nn.functional.cross_entropy(model(values[indices]), targets[indices])
                if not torch.isfinite(loss):
                    raise ValueError("Non-finite loss")
                loss.backward(); optimizer.step()
            if (epoch + 1) % 10 == 0 or epoch == 0:
                print(f"{name}: epoch {epoch + 1}/{args.epochs}, train loss {float(loss):.4f}", flush=True)
    snn_accuracy, snn_matrix = evaluate(spiking, values[test_ids], targets[test_ids], 3)
    ann_accuracy, ann_matrix = evaluate(ordinary, values[test_ids], targets[test_ids], 3)
    test_vector = values[test_ids[0]:test_ids[0] + 1]
    with torch.no_grad():
        expected_snn = spiking(test_vector)[0].tolist()
        expected_ann = ordinary(test_vector)[0].tolist()
    batch = lambda fold: str(uuid.uuid5(uuid.NAMESPACE_URL, f"SeeSound/ESC50/{COMMIT}/fold/{fold}")).upper()
    evaluation = {"trainCount": 96, "testCount": 24, "trainBatches": [batch(i) for i in [1, 2, 3, 4]], "testBatches": [batch(5)],
                  "snnAccuracy": snn_accuracy, "annAccuracy": ann_accuracy, "snnConfusion": snn_matrix, "annConfusion": ann_matrix}
    provenance = {"name": "ESC-50 / SeeSound three-class subset", "commit": COMMIT,
                  "sourceURL": "https://github.com/karolpiczak/ESC-50", "license": "CC BY-NC 3.0",
                  "trainFolds": [1, 2, 3, 4], "testFolds": [5],
                  "trainSources": sorted({clips[i]["sourceFile"] for i in train_ids}),
                  "testSources": sorted({clips[i]["sourceFile"] for i in test_ids})}
    model = {"format": "SeeSoundExperiment", "version": 2, "featureSchema": SCHEMA, "encodingStep": 0.08,
             "trainingKind": "esc50-public", "dataset": provenance, "labels": LABELS,
             "beta": float(spiking.neuron.beta), "threshold": float(spiking.neuron.threshold),
             "snnHidden": parameters(spiking.hidden), "snnOutput": parameters(spiking.output),
             "annHidden": parameters(ordinary.hidden), "annOutput": parameters(ordinary.output),
             "testInput": test_vector[0].tolist(), "expectedSNN": expected_snn, "expectedANN": expected_ann, "evaluation": evaluation}
    args.output.mkdir(parents=True, exist_ok=True)
    model_path = args.output / "ESC50-Model.json"
    model_path.write_text(json.dumps(model, indent=2, allow_nan=False))
    catalog = {"format": "SeeSoundPublicCatalog", "version": 1, "commit": COMMIT, "featureSchema": SCHEMA,
               "clips": [clips[i] for i in test_ids]}
    (args.output / "ESC50-Catalog.json").write_text(json.dumps(catalog, separators=(",", ":"), allow_nan=False))
    audio_folder = args.output / "PublicAudio"; audio_folder.mkdir(exist_ok=True)
    for i in test_ids:
        shutil.copy2(args.data / "audio" / clips[i]["id"], audio_folder / clips[i]["id"])
    report = {"kind": "public-dataset-holdout", "seed": 2026, "epochs": args.epochs,
              "torch": torch.__version__, "snntorch": snntorch.__version__, "numpy": np.__version__,
              "dataset": provenance, "evaluation": evaluation, "featureSchema": SCHEMA,
              "trainIDs": [clips[i]["id"] for i in train_ids], "testIDs": [clips[i]["id"] for i in test_ids],
              "featuresSHA256": hashlib.sha256((args.data / "features.json").read_bytes()).hexdigest(),
              "modelSHA256": hashlib.sha256(model_path.read_bytes()).hexdigest(),
              "selection": "Fixed before training: 40 knock / 40 clapping / 40 other (keyboard + vacuum).",
              "evaluationPolicy": "Official folds 1-4 train, fold 5 test once after fixed epochs. No test-based checkpoint or hyperparameter selection.",
              "limitations": ["24 selected public test clips only; not the full ESC-50 benchmark.",
                              "Other means keyboard/vacuum in this experiment, not all unknown sounds.",
                              "Original ESC-50 documentation notes possible class-dependent preprocessing artifacts.",
                              "No user home recordings, live microphone validation, device energy or fair latency benchmark."]}
    (args.output / "ESC50-Report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(evaluation), flush=True)
    print("Public dataset model and all 24 held-out audio clips exported; no user audio.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--epochs", type=int, default=80)
    train(parser.parse_args())
