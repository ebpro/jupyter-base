#!/usr/bin/env python3
"""Normalize feature.json files under features:
 remove leading repo prefix in `id` (e.g. `solen/foo` -> `foo`)
"""
from pathlib import Path
import json
from json import JSONDecodeError

ROOT = Path(__file__).resolve().parents[1]
FEATURES = ROOT / '.devcontainer' / 'features'

def load_first_json(text: str):
    decoder = json.JSONDecoder()
    try:
        obj, idx = decoder.raw_decode(text)
        return obj
    except JSONDecodeError as e:
        # try naive split: look for first trailing '}' that starts a new object
        # fallback: attempt to find the first occurrence of '\n}\n' and cut
        # This is a best-effort repair for files that accidentally concatenated JSON.
        for sep in ['\n}\n', '\n}\r\n', '\n}\n{']:
            i = text.find(sep)
            if i != -1:
                candidate = text[:i+2]
                try:
                    obj, _ = decoder.raw_decode(candidate)
                    return obj
                except JSONDecodeError:
                    continue
        raise

def normalize_feature(path: Path):
    t = path.read_text(encoding='utf-8')
    try:
        meta = load_first_json(t)
    except Exception as e:
        print(f"ERROR parsing {path}: {e}")
        return False
    changed = False
    if 'id' in meta and isinstance(meta['id'], str) and '/' in meta['id']:
        newid = meta['id'].split('/')[-1]
        meta['id'] = newid
        changed = True
    if 'id' in meta and ('name' not in meta or meta.get('name') != meta['id']):
        meta['name'] = meta['id']
        changed = True
    if 'version' not in meta:
        meta['version'] = '0.1.0'
        changed = True
    if changed:
        path.write_text(json.dumps(meta, indent=2) + "\n", encoding='utf-8')
        print(f"Updated {path.name}")
    return True

def main():
    if not FEATURES.exists():
        print("No features dir")
        return
    for d in sorted(FEATURES.iterdir()):
        if not d.is_dir():
            continue
        if d.name.startswith('_'):
            continue
        p = d / 'feature.json'
        if not p.exists():
            continue
        normalize_feature(p)

if __name__ == '__main__':
    main()
