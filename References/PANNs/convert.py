"""Convert the official PANNs Cnn10 checkpoint; keep the published network weights.
Run from the project root: /Users/mac/snn-env/bin/python References/PANNs/convert.py
The macOS conversion check uses public ESC-50 files only.
"""
from pathlib import Path
import sys, json, hashlib
import numpy as np
import torch
from torch import nn
import torch.nn.functional as F
import coremltools as ct
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(Path(__file__).parent))
from models import Cnn10

torch.set_num_threads(2)
checkpoint=Path('/tmp/PANNs-Cnn10.pth')
source=Cnn10(32000,1024,320,64,50,14000,527).eval()
source.load_state_dict(torch.load(checkpoint,map_location='cpu',weights_only=True)['model'])
class FeaturesNetwork(nn.Module):
    def __init__(self,net):
        super().__init__();self.net=net
    def forward(self,x):
        x=self.net.bn0(x.transpose(1,3)).transpose(1,3)
        for block in [self.net.conv_block1,self.net.conv_block2,self.net.conv_block3,self.net.conv_block4]:
            x=block(x,pool_size=(2,2),pool_type='avg')
        x=x.mean(dim=3)
        x=x.max(dim=2)[0]+x.mean(dim=2)
        x=F.relu(self.net.fc1(x))
        return torch.sigmoid(self.net.fc_audioset(x))

wrapper=FeaturesNetwork(source).eval()
example=torch.zeros(1,1,501,64)
traced=torch.jit.trace(wrapper,example)
model=ct.convert(traced,inputs=[ct.TensorType(name='features',shape=(1,1,501,64),dtype=np.float32)],outputs=[ct.TensorType(name='scores',dtype=np.float32)],minimum_deployment_target=ct.target.iOS16,compute_precision=ct.precision.FLOAT16)
model.author='Qiuqiang Kong et al.; SeeSound Core ML packaging'
model.license='Code: MIT. Pretrained weights: CC BY 4.0, Qiuqiang Kong et al., doi:10.5281/zenodo.3987831. Core ML float16 conversion.'
model.short_description='PANNs Cnn10 AudioSet 527 classes. Native 32 kHz log-mel frontend, fixed 5 s windows.'
model.save(str(ROOT/'Resources/PANNsCnn10.mlpackage'))
weights=source.logmel_extractor.melW.detach().numpy().T.astype(float)
(ROOT/'Resources/PANNs-Mel.json').write_text(json.dumps(weights.tolist(),separators=(',',':')))
# Retain a deterministic frontend fixture and the reference output.
samples=(.08*np.sin(2*np.pi*440*np.arange(160000)/32000)).astype(np.float32)
with torch.no_grad():
    x=torch.from_numpy(samples[None,:]);features=source.logmel_extractor(source.spectrogram_extractor(x));ref=source(x)['clipwise_output'].numpy().flatten(); via=wrapper(features).numpy().flatten()
assert np.max(np.abs(ref-via))<1e-6
pred=model.predict({'features':features.numpy()})['scores'].flatten()
fixture={'samples':len(samples),'frequency':440,'amplitude':.08,'feature_first':features.numpy().flatten()[:128].tolist(),'feature_selected':[[i,float(features.numpy().flatten()[i])] for i in [0,100,1000,3200,10000,20000,32063]],'score_max_abs_error':float(np.max(np.abs(ref-pred))),'reference_top5':np.argsort(ref)[-5:][::-1].tolist(),'coreml_top5':np.argsort(pred)[-5:][::-1].tolist(),'checkpoint_sha256':hashlib.sha256(checkpoint.read_bytes()).hexdigest(),'torch':torch.__version__,'coremltools':ct.__version__}
(ROOT/'References/PANNs/conversion-check.json').write_text(json.dumps(fixture,indent=2))
print(json.dumps(fixture,indent=2))
