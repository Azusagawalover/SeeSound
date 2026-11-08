"""Convert a pristine YAMNet package to float32 I/O, preserving the pretrained network.
Usage: python portable_io.py /path/to/original.mlpackage /path/to/output.mlpackage
The output retains Core ML's _to_fp32 suffix; SeeSound accepts both interface versions.
"""
import sys,coremltools as ct
from coremltools.proto.FeatureTypes_pb2 import ArrayFeatureType
m=ct.models.MLModel(sys.argv[1],skip_model_load=True)
u=ct.models.utils.change_input_output_tensor_type(m,from_type=ArrayFeatureType.FLOAT16,to_type=ArrayFeatureType.FLOAT32,input_names=['features']);u.save(sys.argv[2])
