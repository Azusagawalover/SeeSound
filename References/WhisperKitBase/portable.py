"""Make portable float32-I/O wrappers for Whisper Base (weights unchanged).
Sources: downloaded Argmax Core ML encoder/decoder, OpenAI Whisper mel equations.
"""
from pathlib import Path
import numpy as np,torch,librosa,coremltools as ct,json
from torch import nn
from coremltools.proto.FeatureTypes_pb2 import ArrayFeatureType
ROOT=Path(__file__).resolve().parents[2]
ORIGINAL=Path('/tmp/SeeSound-WhisperBase/models/argmaxinc/whisperkit-coreml/openai_whisper-base')
OUT=ROOT/'Resources/SpeechBaseSources';OUT.mkdir(exist_ok=True)
torch.set_num_threads(2)
for name in ['AudioEncoder','TextDecoder']:
 spec=ct.utils.load_spec(str(ORIGINAL/(name+'.mlmodelc/model.mlmodel')));source=ct.models.MLModel(spec,weights_dir=str(ORIGINAL/(name+'.mlmodelc/weights')),skip_model_load=True)
 names=list(source.get_spec().description.input);updated=ct.models.utils.change_input_output_tensor_type(source,from_type=ArrayFeatureType.FLOAT16,to_type=ArrayFeatureType.FLOAT32,input_names=[x.name for x in names])
 updated.license='MIT. OpenAI Whisper / Argmax Core ML conversion. SeeSound: float32 input/output adapters; pretrained weights unchanged.'
 updated.save(str(OUT/(name+'.mlpackage')));print(name,'saved',flush=True)
class Mel(nn.Module):
 def __init__(self):
  super().__init__();n=np.arange(400);window=.5-.5*np.cos(2*np.pi*n/400)
  angle=2*np.pi*np.arange(201)[:,None]*n[None,:]/400
  self.register_buffer('real',torch.from_numpy((np.cos(angle)*window).astype(np.float32))[:,None,:]);self.register_buffer('imag',torch.from_numpy((-np.sin(angle)*window).astype(np.float32))[:,None,:]);self.register_buffer('mel',torch.from_numpy(librosa.filters.mel(sr=16000,n_fft=400,n_mels=80)))
 def forward(self,audio):
  x=torch.nn.functional.pad(audio[None,None,:],(200,200),mode='reflect')
  real=torch.nn.functional.conv1d(x,self.real,stride=160)[:,:,:-1];imag=torch.nn.functional.conv1d(x,self.imag,stride=160)[:,:,:-1]
  values=self.mel@(real.square()+imag.square())[0]
  log=torch.log10(torch.clamp(values,min=1e-10));log=torch.maximum(log,log.max()-8);return ((log+4)/4)[None,:,None,:]
mel=Mel().eval();trace=torch.jit.trace(mel,torch.zeros(480000))
model=ct.convert(trace,inputs=[ct.TensorType(name='audio',shape=(480000,),dtype=np.float32)],outputs=[ct.TensorType(name='melspectrogram_features',dtype=np.float32)],minimum_deployment_target=ct.target.iOS16,compute_precision=ct.precision.FLOAT16)
model.license='MIT. OpenAI Whisper mel frontend equations; SeeSound Core ML float32-I/O conversion.'
model.save(str(OUT/'MelSpectrogram.mlpackage'));print('MelSpectrogram saved',flush=True)
