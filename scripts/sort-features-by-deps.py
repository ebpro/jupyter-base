#!/usr/bin/env python3
"""Topological sort of features by dependency order."""
import json
import sys
from pathlib import Path
from collections import defaultdict, deque

features_dir = Path(__file__).parent.parent / ".devcontainer" / "features"

def load_deps(feat):
    fp = features_dir / feat / "feature.json"
    if not fp.exists():
        return []
    data = json.loads(fp.read_text())
    return [d for d in data.get("dependsOn", []) if not d.startswith("_lib/")]

# Read feature list from stdin
features = [f.strip() for f in sys.stdin if f.strip()]

# Build adjacency
graph = defaultdict(set)
in_degree = defaultdict(int)
for f in features:
    in_degree.setdefault(f, 0)
for f in features:
    for dep in load_deps(f):
        if dep in features:
            graph[dep].add(f)
            in_degree[f] += 1

# Kahn's algorithm
q = deque(f for f in features if in_degree[f] == 0)
result = []
while q:
    node = q.popleft()
    result.append(node)
    for neighbor in sorted(graph[node]):
        in_degree[neighbor] -= 1
        if in_degree[neighbor] == 0:
            q.append(neighbor)

# Append any remaining (cycles)
for f in features:
    if f not in result:
        result.append(f)

for f in result:
    print(f)
