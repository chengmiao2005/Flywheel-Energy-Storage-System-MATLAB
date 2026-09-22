"""Restore compressed native CSV files for the unchanged MATLAB result viewer."""
from pathlib import Path
import gzip,hashlib,json
root=Path(__file__).resolve().parent
for item in json.loads((root/'SOURCE_MANIFEST.json').read_text())['files']:
    if not item['path'].endswith('.gz'):continue
    packed=root/item['path'];target=packed.with_suffix('')
    if target.exists():
        if hashlib.sha256(target.read_bytes()).hexdigest()!=item['original_sha256']:
            raise SystemExit(f'Refusing to replace a modified file: {target}')
        continue
    data=gzip.decompress(packed.read_bytes())
    if hashlib.sha256(data).hexdigest()!=item['original_sha256']:raise SystemExit(f'Hash mismatch: {packed}')
    target.write_bytes(data)
print('Native CSV files are available. Their original SHA-256 hashes match.')
