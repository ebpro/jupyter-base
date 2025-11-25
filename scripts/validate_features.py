#!/usr/bin/env python3
"""Validate feature metadata and presence of install scripts.

Checks each directory under `.devcontainer/features/` for `feature.json` and `install.sh`.
Performs basic schema checks (no external deps required).
"""
import json
from pathlib import Path
import sys
import re

ROOT = Path(__file__).resolve().parents[1]
FEATURES_DIR = ROOT / '.devcontainer' / 'features'
SCHEMA = json.loads((Path(__file__).parent / 'feature_json_schema.json').read_text(encoding='utf-8'))


def validate_metadata(meta: dict, path: Path):
    errors = []
    # required fields
    for key in SCHEMA.get('required', []):
        if key not in meta:
            errors.append(f"missing required '{key}' in {path}")
    # id pattern
    if 'id' in meta:
        if not re.match(r'^[a-z0-9._-]+$', meta['id']):
            errors.append(f"invalid id '{meta['id']}' in {path}; must match [a-z0-9._-]")
    # version presence
    if 'version' in meta:
        if not isinstance(meta['version'], str) or not meta['version'].strip():
            errors.append(f"version must be a non-empty string in {path}")
    # name should match id
    if 'id' in meta and 'name' in meta and meta['id'] != meta['name']:
        errors.append(f"name '{meta.get('name')}' does not match id '{meta.get('id')}' in {path}")
    return errors


def main():
    if not FEATURES_DIR.exists():
        print("No features dir found; skipping feature validation")
        return 0
    failures = []
    for d in sorted(FEATURES_DIR.iterdir()):
        if not d.is_dir():
            continue
        feature_json = d / 'feature.json'
        install_sh = d / 'install.sh'
        if not feature_json.exists():
            failures.append(f"{d.name}: missing feature.json")
            continue
        try:
            meta = json.loads(feature_json.read_text(encoding='utf-8'))
        except Exception as e:
            failures.append(f"{d.name}: feature.json parse error: {e}")
            continue
        failures.extend(validate_metadata(meta, feature_json))
        if not install_sh.exists():
            failures.append(f"{d.name}: missing install.sh")
        else:
            if not install_sh.stat().st_mode & 0o100:
                failures.append(f"{d.name}: install.sh is not executable")

    if failures:
        print("Feature validation FAILED")
        for f in failures:
            print(" -", f)
        return 2
    print("Feature validation: OK")
    return 0


if __name__ == '__main__':
    sys.exit(main())
