#!/usr/bin/env python3
"""Run locally in your Terminal. Never include this private file in source archives."""
import getpass
import json
import os
from pathlib import Path
import secrets

def main():
    root = Path.home() / '.config' / 'seesound'
    root.mkdir(parents=True, exist_ok=True, mode=0o700); root.chmod(0o700)
    target = root / 'deepseek.json'
    key = getpass.getpass('DeepSeek API Key（输入不回显）: ').strip()
    if not key or any(c.isspace() for c in key):
        raise SystemExit('未保存：密钥为空或含空白。')
    token = secrets.token_urlsafe(32)
    model = input('模型名 [deepseek-flash]: ').strip() or 'deepseek-flash'
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd,'w') as f:
        json.dump({'api_key':key,'client_token':token,'model':model}, f)
    target.chmod(0o600)
    print('已保存到用户私密配置目录，未写入项目。')
    print('App 配对码（不是 DeepSeek 密钥，仅复制到你自己的见声 App）：')
    print(token)

if __name__ == '__main__':
    main()
