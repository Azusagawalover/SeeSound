---
license: apache-2.0
library_name: coreml
tags:
  - coreml
  - yamnet
  - audio-classification
  - tensorflow
  - apple
---

# YAMNet Core ML

This is a Core ML conversion of the YAMNet audio event classifier. The model was converted from the TensorFlow Hub YAMNet SavedModel.

Important: this Core ML package does not accept raw waveform audio. It accepts precomputed YAMNet log-mel feature patches shaped `[1, 96, 64]`.

## Model Interface

Input:

- `features`: `MLMultiArray` shaped `[1, 96, 64]`, `Float16`
- Represents one YAMNet log-mel patch: 96 frames x 64 mel bands.

Output:

- `Identity`: `MLMultiArray` shaped `[1, 521]`, `Float16`
- Contains class scores for the 521 YAMNet AudioSet classes.

Class labels are available in:

```text
yamnet_model/assets/yamnet_class_map.csv
```

## Swift Usage

```swift
import CoreML
import Foundation

let modelURL = URL(fileURLWithPath: "YAMNet.mlpackage")
let model = try MLModel(contentsOf: modelURL)

let features = try MLMultiArray(shape: [1, 96, 64], dataType: .float16)

// Fill `features` with YAMNet-compatible log-mel values.
// Layout is [batch, frame, melBand].
for frame in 0..<96 {
    for band in 0..<64 {
        let index = [0, NSNumber(value: frame), NSNumber(value: band)]
        features[index] = 0.0
    }
}

let input = try MLDictionaryFeatureProvider(dictionary: [
    "features": MLFeatureValue(multiArray: features)
])

let output = try model.prediction(from: input)
guard let scores = output.featureValue(for: "Identity")?.multiArrayValue else {
    throw NSError(domain: "YAMNet", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing scores output"])
}

var bestIndex = 0
var bestScore = -Double.infinity
for index in 0..<521 {
    let score = scores[[0, NSNumber(value: index)]].doubleValue
    if score > bestScore {
        bestScore = score
        bestIndex = index
    }
}

print("Top class index: \(bestIndex), score: \(bestScore)")
```

## Feature Extraction

To use this model with raw audio, compute YAMNet-compatible features first:

- sample rate: 16 kHz mono
- STFT window: 25 ms
- STFT hop: 10 ms
- mel bands: 64
- mel range: 125 Hz to 7500 Hz
- log offset: `0.001`
- patch size: 96 frames x 64 mel bands

The original TensorFlow Hub YAMNet model includes waveform preprocessing, but that path uses TensorFlow ops that are not currently supported by Core ML conversion. This package therefore contains only the classifier network after feature extraction.

## Conversion

The package was generated with:

```bash
uv run main.py --model-path ./yamnet_model --output ./YAMNet.mlpackage
```

To download the TensorFlow Hub source model:

```bash
uv run main.py --download-only
```
