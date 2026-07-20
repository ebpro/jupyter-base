#!/usr/bin/env python3
import json
import sys
from pathlib import Path

features_dir = Path(__file__).parent.parent / ".devcontainer" / "features"

seen = set()
queue = []

for line in sys.stdin:
    line = line.strip()
    if line:
        queue.append(line)

order = []
while queue:
    feat = queue.pop(0)
    if feat in seen:
        continue
    seen.add(feat)
    fp = features_dir / feat / "feature.json"
    if fp.exists():
        data = json.loads(fp.read_text())
        for dep in data.get("dependsOn", []):
            if dep.startswith("_lib/"):
                continue
            if dep not in seen:
                queue.append(dep)
    order.append(feat)

for f in order:
    print(f)
