#!/usr/bin/env python3
"""Generate golden features and scores using the pinned, unmodified Google model.

Requires TensorFlow 2.18.1, tf_keras 2.18.0, numpy 2.0.2 and official yamnet.h5.
Only synthetic waveforms; no private recordings or external API requests.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import tensorflow as tf

import features
import params
import yamnet


def signal(name, length):
    t = np.arange(length, dtype=np.float64) / 16000
    if name == 'silence':
        return np.zeros(length, dtype=np.float32)
    if name == 'tones':
        return (0.12 * np.sin(2*np.pi*440*t) + 0.07 * np.sin(2*np.pi*1730*t)).astype(np.float32)
    if name == 'sweep':
        return (0.2 * np.sin(2*np.pi*(150*t + 1800*t*t)) * np.exp(-2*t)).astype(np.float32)
    raise ValueError(name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--weights', required=True, type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'Checks/Fixtures/YAMNetReference.json')
    args = parser.parse_args()
    parameters = params.Params()
    model = yamnet.yamnet_frames_model(parameters)
    model.load_weights(str(args.weights))
    cases = []
    for name, length in [('silence', 1600), ('tones', 15600), ('sweep', 24000)]:
        waveform = signal(name, length)
        padded = features.pad_waveform(tf.constant(waveform), parameters)
        _, patches = features.waveform_to_log_mel_spectrogram_patches(padded, parameters)
        scores, _, _ = model(waveform)
        cases.append({'signal': name, 'length': length, 'patches': patches.numpy().reshape((-1, 6144)).tolist(),
                      'meanScores': np.mean(scores.numpy(), axis=0).tolist()})
    reference = {'tensorflow': tf.__version__, 'upstreamRevision': 'c14bf9ad91962cf189f9f58db2132c06247fcd53',
                 'weightsSHA256': hashlib.sha256(args.weights.read_bytes()).hexdigest(), 'cases': cases}
    args.output.write_text(json.dumps(reference, separators=(',', ':')) + '\n')
    print('Generated', len(cases), 'synthetic TensorFlow reference cases:', args.output)


if __name__ == '__main__':
    main()
