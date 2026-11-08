"""Package the fixed public holdout and its notices; do not alter trained weights or scores."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from prepare_esc50 import COMMIT


def package(data, build, project):
    catalog = json.loads((build / "ESC50-Catalog.json").read_text())
    model = json.loads((build / "ESC50-Model.json").read_text())
    if catalog["commit"] != COMMIT or model["dataset"]["commit"] != COMMIT:
        raise ValueError("Unexpected source version")
    attribution = (data / "LICENSE.upstream.txt").read_text().splitlines()
    for clip in catalog["clips"]:
        key = "[" + clip["id"].rsplit("-", 1)[0] + ".ogg]"
        matches = [line for line in attribution if key in line]
        if len(matches) != 1:
            raise ValueError("Missing / ambiguous original attribution for " + clip["id"])
        clip["attribution"] = matches[0]
        audio = build / "PublicAudio" / clip["id"]
        if hashlib.sha256(audio.read_bytes()).hexdigest() != clip["sha256"]:
            raise ValueError("Audio checksum mismatch")
    resources = project / "Resources"; resources.mkdir(exist_ok=True)
    (resources / "ESC50-Catalog.json").write_text(json.dumps(catalog, separators=(",", ":"), allow_nan=False))
    shutil.copy2(build / "ESC50-Model.json", resources / "ESC50-Model.json")
    audio_folder = resources / "PublicAudio"; audio_folder.mkdir(exist_ok=True)
    for clip in catalog["clips"]:
        shutil.copy2(build / "PublicAudio" / clip["id"], audio_folder / clip["id"])
    shutil.copy2(data / "LICENSE.upstream.txt", resources / "ESC50-LICENSE.txt")
    reference = project / "References" / "ESC50"; reference.mkdir(parents=True, exist_ok=True)
    for source, name in [("LICENSE.upstream.txt", "LICENSE.txt"), ("esc50.csv", "esc50.upstream.csv"), ("selection.json", "selection.json")]:
        shutil.copy2(data / source, reference / name)
    results = project / "Training" / "Results"; results.mkdir(exist_ok=True)
    shutil.copy2(build / "ESC50-Report.json", results / "ESC50-Report.json")
    print("Packaged 24 held-out clips, fixed model, catalog, source metadata and complete upstream attribution.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    args = parser.parse_args()
    package(args.data, args.build, args.project)
