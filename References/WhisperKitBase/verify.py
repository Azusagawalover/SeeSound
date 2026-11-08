"""Compare original and portable Core ML models on one labelled synthetic fixture.
No microphone, private files or API calls. This is a conversion check, not an ASR benchmark.
"""
import json
from pathlib import Path
import numpy as np,librosa,soundfile as sf,coremltools as ct
ROOT=Path(__file__).resolve().parents[2]
ORIGINAL=Path('/tmp/SeeSound-WhisperBase/models/argmaxinc/whisperkit-coreml/openai_whisper-base')
x,sr=sf.read(str(ROOT/'Resources/ValidationSpeech.aiff'));x=librosa.resample(x.astype(np.float32),orig_sr=sr,target_sr=16000);x=np.pad(x,(0,480000-len(x)))
def evaluate(portable):
 models={}
 for name in ['MelSpectrogram','AudioEncoder','TextDecoder']:
  models[name]=ct.models.MLModel(str(ROOT/'Resources/SpeechBaseSources'/(name+'.mlpackage')),compute_units=ct.ComputeUnit.CPU_AND_GPU) if portable else ct.models.CompiledMLModel(str(ORIGINAL/(name+'.mlmodelc')),compute_units=ct.ComputeUnit.CPU_AND_GPU)
 def call(name,data):return {k.removesuffix('_to_fp32'):v for k,v in models[name].predict(data).items()}
 dtype=np.float32 if portable else np.float16
 mel=call('MelSpectrogram',{'audio':x.astype(dtype)})['melspectrogram_features']
 encoder=call('AudioEncoder',{'melspectrogram_features':mel})['encoder_output_embeds']
 key=np.zeros((1,3072,1,224),dtype=dtype);value=key.copy();padding=np.ones((1,224),dtype=dtype)*-10000
 tokens=[];prompt=[50258,50259,50359,50364]
 for position in range(80):
  token=prompt[position] if position<len(prompt) else tokens[-1]
  padding[0,position]=0;mask=np.zeros((1,224),dtype=dtype);mask[0,position]=1
  out=call('TextDecoder',{'input_ids':np.array([token],dtype=np.int32),'cache_length':np.array([position],dtype=np.int32),'key_cache':key,'value_cache':value,'kv_cache_update_mask':mask,'encoder_output_embeds':encoder,'decoder_key_padding_mask':padding})
  key[:,:,:,position:position+1]=out['key_cache_updates'];value[:,:,:,position:position+1]=out['value_cache_updates']
  token=int(np.argmax(out['logits'].astype(np.float32)));tokens.append(token)
  if token==50257 and position>=len(prompt):break
 return mel,encoder,tokens
original=evaluate(False);portable=evaluate(True)
report={'fixture':'macOS Samantha synthetic speech, 3.4 seconds, English','expected_prompt':'Please bring your student card to the service centre tomorrow morning.','original_tokens':original[2],'portable_tokens':portable[2],'same_tokens':original[2]==portable[2],'mel_max_absolute_error':float(np.max(np.abs(original[0].astype(np.float32)-portable[0].astype(np.float32)))),'encoder_mean_absolute_error':float(np.mean(np.abs(original[1].astype(np.float32)-portable[1].astype(np.float32)))),'scope':'One synthetic conversion fixture; no claim of Chinese/natural speech accuracy or real device speed.'}
(ROOT/'References/WhisperKitBase/conversion-check.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));assert report['same_tokens'],'Converted model generated different tokens; review required'
