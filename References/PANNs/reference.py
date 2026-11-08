"""Generate parity fixtures from official PyTorch weights, no personal recordings."""
import json,sys
from pathlib import Path
import torch,numpy as np
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(Path(__file__).parent))
from models import Cnn10
torch.set_num_threads(2)
model=Cnn10(32000,1024,320,64,50,14000,527).eval()
model.load_state_dict(torch.load('/tmp/PANNs-Cnn10.pth',map_location='cpu',weights_only=True)['model'])
samples=[];state=13
for i in range(160000):
 state=(1664525*state+1013904223)&0xffffffff
 noise=((state>>8)/16777216-.5)*.002
 samples.append(.08*np.sin(2*np.pi*440*i/32000)+noise)
x=torch.tensor([samples],dtype=torch.float32)
with torch.no_grad():
 features=model.logmel_extractor(model.spectrogram_extractor(x)).numpy().flatten()
 scores=model(x)['clipwise_output'].numpy().flatten()
ref={'features':features.tolist(),'scores':scores.tolist(),'signal':'440Hz sine + deterministic uniform noise, 32kHz, 5s','upstream':'https://zenodo.org/records/3987831'}
(ROOT/'Checks/Fixtures/PANNsReference.json').write_text(json.dumps(ref,separators=(',',':')))
print('Reference generated:',len(features),'features;',len(scores),'scores')
