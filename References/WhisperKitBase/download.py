"""Fetch pinned public model files and verify SHA-256 before replacing anything."""
import argparse,hashlib,json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import quote
import requests
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=Path('/tmp/SeeSound-WhisperBase'));p.add_argument('--proxy');args=p.parse_args()
manifest=json.loads((Path(__file__).parent/'download-manifest.json').read_text())
proxies={'http':args.proxy,'https':args.proxy} if args.proxy else None
def fetch(item):
 repo=item['repo'];relative=Path(item['path'])
 if repo not in ['argmaxinc/whisperkit-coreml','openai/whisper-base'] or relative.is_absolute() or '..' in relative.parts:raise ValueError('invalid manifest path')
 target=args.output/'models'/repo/relative;target.parent.mkdir(parents=True,exist_ok=True)
 if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest()==item['sha256']:return str(relative)
 temporary=target.with_name(target.name+'.partial')
 try:
  with requests.get('https://huggingface.co/'+repo+'/resolve/'+item['revision']+'/'+quote(str(relative),safe='/'),stream=True,proxies=proxies,timeout=120) as response:
   response.raise_for_status()
   with temporary.open('wb') as output:
    for chunk in response.iter_content(1024*1024):output.write(chunk)
  if temporary.stat().st_size!=item['size'] or hashlib.sha256(temporary.read_bytes()).hexdigest()!=item['sha256']:raise ValueError('model checksum mismatch')
  temporary.replace(target)
 finally:
  temporary.unlink(missing_ok=True)
 return str(relative)
with ThreadPoolExecutor(max_workers=3) as pool:
 for name in pool.map(fetch,manifest):print(name,flush=True)
