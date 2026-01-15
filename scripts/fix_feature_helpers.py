#!/usr/bin/env python3
import pathlib
from pathlib import Path
root = Path(__file__).resolve().parents[1]
count=0
for p in root.glob('features/**/install.sh'):
    s = p.read_text()
    new = s.replace('../../../scripts/feature_helpers.sh','../../../scripts/lib/features.sh')
    if new != s:
        p.write_text(new)
        count += 1
print(f"Updated {count} files")
