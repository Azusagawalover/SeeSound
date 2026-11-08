import argparse
import shutil
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import coremltools as ct
import tensorflow as tf

DEFAULT_TFHUB_URL = "https://tfhub.dev/google/yamnet/1?tf-hub-format=compressed"


def parse_args():
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Convert YAMNet TensorFlow SavedModel to Core ML.")
    parser.add_argument(
        "--model-path",
        default=script_dir / "yamnet_model",
        type=Path,
        help="Path to a TensorFlow SavedModel directory, .keras file, or .h5 file.",
    )
    parser.add_argument(
        "--output",
        default=script_dir / "YAMNet.mlpackage",
        type=Path,
        help="Output Core ML package path.",
    )
    parser.add_argument(
        "--waveform-samples",
        default=15_600,
        type=int,
        help="Fixed waveform length for the Core ML input. YAMNet commonly uses 0.975s at 16 kHz.",
    )
    parser.add_argument(
        "--output-key",
        default=None,
        help="SavedModel output key for --conversion-mode waveform. Defaults to output_0 for TFHub YAMNet.",
    )
    parser.add_argument(
        "--conversion-mode",
        choices=["features", "waveform"],
        default="features",
        help=(
            "features converts the YAMNet classifier from 96x64 log-mel patches and avoids unsupported "
            "TensorFlow FFT ops. waveform attempts direct full SavedModel conversion."
        ),
    )
    parser.add_argument(
        "--download-tfhub",
        action="store_true",
        help="Download YAMNet from TFHub into --model-path before conversion if it is missing.",
    )
    parser.add_argument(
        "--force-download",
        action="store_true",
        help="Replace --model-path with a fresh TFHub download before conversion.",
    )
    parser.add_argument(
        "--download-only",
        action="store_true",
        help="Download YAMNet from TFHub into --model-path and exit without Core ML conversion.",
    )
    parser.add_argument(
        "--tfhub-url",
        default=DEFAULT_TFHUB_URL,
        help="TFHub compressed SavedModel URL.",
    )
    return parser.parse_args()


@dataclass(frozen=True)
class YamnetParams:
    patch_frames: int = 96
    patch_bands: int = 64
    num_classes: int = 521
    conv_padding: str = "same"
    batchnorm_center: bool = True
    batchnorm_scale: bool = False
    batchnorm_epsilon: float = 1e-4
    classifier_activation: str = "sigmoid"


YAMNET_LAYER_DEFS = [
    ("conv", [3, 3], 2, 32),
    ("separable_conv", [3, 3], 1, 64),
    ("separable_conv", [3, 3], 2, 128),
    ("separable_conv", [3, 3], 1, 128),
    ("separable_conv", [3, 3], 2, 256),
    ("separable_conv", [3, 3], 1, 256),
    ("separable_conv", [3, 3], 2, 512),
    ("separable_conv", [3, 3], 1, 512),
    ("separable_conv", [3, 3], 1, 512),
    ("separable_conv", [3, 3], 1, 512),
    ("separable_conv", [3, 3], 1, 512),
    ("separable_conv", [3, 3], 1, 512),
    ("separable_conv", [3, 3], 2, 1024),
    ("separable_conv", [3, 3], 1, 1024),
]


def download_tfhub_saved_model(tfhub_url, model_path, force=False):
    if model_path.exists() and not force:
        print(f"Using existing model: {model_path}")
        return

    if model_path.exists():
        if model_path.is_dir():
            shutil.rmtree(model_path)
        else:
            model_path.unlink()

    model_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading TFHub model: {tfhub_url}")

    with tempfile.TemporaryDirectory(prefix="yamnet-tfhub-") as temp_dir:
        archive_path = Path(temp_dir) / "model.tar.gz"
        request = urllib.request.Request(tfhub_url, headers={"User-Agent": "langpipe-yamnet-coreml"})
        with urllib.request.urlopen(request) as response, archive_path.open("wb") as archive:
            shutil.copyfileobj(response, archive)

        extract_path = Path(temp_dir) / "model"
        extract_path.mkdir()
        with tarfile.open(archive_path, "r:gz") as tar:
            tar.extractall(extract_path, filter="data")

        saved_model_pb = next(extract_path.rglob("saved_model.pb"), None)
        if saved_model_pb is None:
            raise ValueError(f"TFHub archive did not contain saved_model.pb: {tfhub_url}")

        extracted_model_root = saved_model_pb.parent
        shutil.copytree(extracted_model_root, model_path)

    print(f"Saved TFHub model: {model_path}")


def batch_norm(name, params, layer_input):
    return tf.keras.layers.BatchNormalization(
        name=name,
        center=params.batchnorm_center,
        scale=params.batchnorm_scale,
        epsilon=params.batchnorm_epsilon,
    )(layer_input)


def build_yamnet_feature_model(params=YamnetParams()):
    features = tf.keras.Input(
        shape=(params.patch_frames, params.patch_bands),
        dtype=tf.float32,
        name="features",
    )
    net = tf.keras.layers.Reshape(
        (params.patch_frames, params.patch_bands, 1),
        name="features_4d",
    )(features)

    for layer_index, (layer_type, kernel, stride, filters) in enumerate(YAMNET_LAYER_DEFS, start=1):
        prefix = f"layer{layer_index}"
        if layer_type == "conv":
            net = tf.keras.layers.Conv2D(
                name=f"{prefix}_conv",
                filters=filters,
                kernel_size=kernel,
                strides=stride,
                padding=params.conv_padding,
                use_bias=False,
                activation=None,
            )(net)
            net = batch_norm(f"{prefix}_conv_bn", params, net)
            net = tf.keras.layers.ReLU(name=f"{prefix}_relu")(net)
            continue

        net = tf.keras.layers.DepthwiseConv2D(
            name=f"{prefix}_depthwise_conv",
            kernel_size=kernel,
            strides=stride,
            depth_multiplier=1,
            padding=params.conv_padding,
            use_bias=False,
            activation=None,
        )(net)
        net = batch_norm(f"{prefix}_depthwise_conv_bn", params, net)
        net = tf.keras.layers.ReLU(name=f"{prefix}_depthwise_relu")(net)
        net = tf.keras.layers.Conv2D(
            name=f"{prefix}_pointwise_conv",
            filters=filters,
            kernel_size=(1, 1),
            strides=1,
            padding=params.conv_padding,
            use_bias=False,
            activation=None,
        )(net)
        net = batch_norm(f"{prefix}_pointwise_conv_bn", params, net)
        net = tf.keras.layers.ReLU(name=f"{prefix}_pointwise_relu")(net)

    embeddings = tf.keras.layers.GlobalAveragePooling2D(name="embeddings")(net)
    logits = tf.keras.layers.Dense(units=params.num_classes, use_bias=True, name="dense")(embeddings)
    class_scores = tf.keras.layers.Activation(
        activation=params.classifier_activation,
        name="class_scores",
    )(logits)
    return tf.keras.Model(name="yamnet_features", inputs=features, outputs=class_scores)


def load_feature_model_weights_from_saved_model(model, model_path):
    loaded = tf.saved_model.load(str(model_path))
    if not hasattr(loaded, "_yamnet"):
        raise ValueError("SavedModel does not expose the expected TFHub YAMNet _yamnet object.")

    source_weights = list(loaded._yamnet.variables)
    target_weights = model.weights
    if len(source_weights) != len(target_weights):
        raise ValueError(f"Weight count mismatch: source={len(source_weights)}, target={len(target_weights)}")

    for index, (target, source) in enumerate(zip(target_weights, source_weights)):
        if tuple(target.shape) != tuple(source.shape):
            raise ValueError(
                f"Weight shape mismatch at {index}: target {target.name} {target.shape}, "
                f"source {source.name} {source.shape}"
            )

    model.set_weights([weight.numpy() for weight in source_weights])


def describe_signature(signature):
    _, keyword_specs = signature.structured_input_signature
    print("SavedModel inputs:")
    for name, spec in keyword_specs.items():
        print(f"  {name}: shape={spec.shape}, dtype={spec.dtype.name}")

    print("SavedModel outputs:")
    for name, spec in signature.structured_outputs.items():
        print(f"  {name}: shape={spec.shape}, dtype={spec.dtype.name}")


def select_output_key(signature, requested_key):
    outputs = signature.structured_outputs
    if requested_key:
        if requested_key not in outputs:
            raise ValueError(f"--output-key {requested_key!r} not found. Available keys: {list(outputs)}")
        return requested_key

    if "output_0" in outputs:
        return "output_0"

    for key in outputs:
        if "score" in key.lower() or "class" in key.lower():
            return key

    if not outputs:
        raise ValueError("SavedModel serving_default has no outputs.")
    return next(iter(outputs))


class SavedModelClassScores(tf.Module):
    def __init__(self, signature, input_key, output_key):
        super().__init__()
        self.signature = signature
        self.input_key = input_key
        self.output_key = output_key

    @tf.function
    def __call__(self, waveform):
        outputs = self.signature(**{self.input_key: waveform})
        return {"class_scores": outputs[self.output_key]}


def convert_saved_model(model_path, output_path, waveform_samples, output_key):
    loaded = tf.saved_model.load(str(model_path))
    if "serving_default" not in loaded.signatures:
        raise ValueError(f"SavedModel has no serving_default signature. Available: {list(loaded.signatures)}")

    signature = loaded.signatures["serving_default"]
    describe_signature(signature)

    _, keyword_specs = signature.structured_input_signature
    if len(keyword_specs) != 1:
        raise ValueError(
            "Expected one SavedModel input. Pass a wrapper model if this SavedModel has "
            f"{len(keyword_specs)} inputs: {list(keyword_specs)}"
        )

    input_key = next(iter(keyword_specs))
    selected_output = select_output_key(signature, output_key)
    print(f"Converting input {input_key!r} -> output {selected_output!r} as 'class_scores'")

    wrapper = SavedModelClassScores(signature, input_key, selected_output)
    concrete = wrapper.__call__.get_concrete_function(
        tf.TensorSpec([waveform_samples], tf.float32, name="waveform")
    )

    return ct.convert(
        [concrete],
        source="tensorflow",
        inputs=[ct.TensorType(shape=(waveform_samples,), name="waveform")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )


def convert_keras_model(model_path, output_path):
    model = tf.keras.models.load_model(str(model_path))
    return ct.convert(
        model,
        inputs=[ct.TensorType(shape=(1, 64, 96, 1), name="features")],
        outputs=[ct.TensorType(name="class_scores")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )


def convert_feature_model(model_path):
    model = build_yamnet_feature_model()
    model(tf.zeros((1, 96, 64), dtype=tf.float32))
    load_feature_model_weights_from_saved_model(model, model_path)
    return ct.convert(
        model,
        source="tensorflow",
        inputs=[ct.TensorType(shape=(1, 96, 64), name="features")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
    )


def main():
    args = parse_args()
    if args.download_tfhub or args.force_download or args.download_only:
        download_tfhub_saved_model(args.tfhub_url, args.model_path, force=args.force_download)
    if args.download_only:
        return

    if not args.model_path.exists():
        raise FileNotFoundError(
            f"Model path does not exist: {args.model_path}. "
            "Pass --download-tfhub to download YAMNet from TFHub."
        )

    if args.conversion_mode == "features":
        mlmodel = convert_feature_model(args.model_path)
    elif args.model_path.suffix in {".keras", ".h5", ".hdf5"}:
        mlmodel = convert_keras_model(args.model_path, args.output)
    else:
        mlmodel = convert_saved_model(
            args.model_path,
            args.output,
            args.waveform_samples,
            args.output_key,
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(args.output))
    print(f"Saved Core ML model: {args.output}")


if __name__ == "__main__":
    main()
