#!/usr/bin/env python3
"""Cleanup profiles:
- remove `@profile:` lines that are identical to `@parent:` (redundant)
- remove feature lines in a child that are already provided by its @parent chain

This script modifies files in-place and creates a `.bak` backup for each file changed.
"""
from pathlib import Path
from typing import List, Dict, Set
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "profiles"


def read_profile(path: Path) -> List[str]:
    return path.read_text(encoding="utf-8").splitlines()


def write_profile(path: Path, lines: List[str]):
    bak = path.with_suffix(path.suffix + ".bak")
    path.replace(bak)
    bak.write_text("\n".join(lines) + "\n", encoding="utf-8")
    # move bak back to original name
    bak.replace(path)


def extract_body(lines: List[str]) -> (int, int, List[str]):
    # find first and last fences ``` lines
    first = None
    last = None
    for i, l in enumerate(lines):
        if l.strip().startswith("```"):
            if first is None:
                first = i
            last = i
    if first is None or last is None or last <= first:
        # treat entire file as body
        return 0, len(lines), lines[:]
    return first, last, lines[first+1:last]


def parse_directives_and_features(body: List[str]):
    parents = []
    profiles = []
    features = []
    for l in body:
        s = l.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("@parent:"):
            parents.append(s.split(":", 1)[1].strip())
            continue
        if s.startswith("@profile:"):
            profiles.append(s.split(":", 1)[1].strip())
            continue
        features.append(s)
    return parents, profiles, features


def build_profiles_index() -> Dict[str, List[str]]:
    idx = {}
    for p in PROFILES.iterdir():
        if not p.is_file():
            continue
        name = p.name
        lines = read_profile(p)
        _, _, body = extract_body(lines)
        _, _, features = parse_directives_and_features(body)
        idx[name] = features
    return idx


def resolve_composed_features(name: str, files: Dict[str, Path], visited=None) -> List[str]:
    if visited is None:
        visited = set()
    if name in visited:
        return []
    visited.add(name)
    path = files.get(name)
    if not path:
        return []
    lines = read_profile(path)
    _, _, body = extract_body(lines)
    parents, profiles, features = parse_directives_and_features(body)
    out = []
    # include features from @profile compositions first
    for prof in profiles:
        out += resolve_composed_features(prof, files, visited)
    # include own features
    for f in features:
        if f not in out:
            out.append(f)
    return out


def resolve_parent_chain_features(name: str, files: Dict[str, Path]) -> List[str]:
    # follow @parent chain upwards and collect composed+own features for each parent
    out = []
    visited = set()
    cur = name
    while True:
        path = files.get(cur)
        if not path:
            break
        lines = read_profile(path)
        _, _, body = extract_body(lines)
        parents, profiles, features = parse_directives_and_features(body)
        if not parents:
            break
        parent = parents[0]
        if parent in visited:
            break
        visited.add(parent)
        # parent provided features include its composed features
        parent_feats = resolve_composed_features(parent, files)
        for f in parent_feats:
            if f not in out:
                out.append(f)
        cur = parent
    return out


def main():
    files = {p.name: p for p in PROFILES.iterdir() if p.is_file()}
    modified = []
    for name, path in files.items():
        lines = read_profile(path)
        first, last, body = extract_body(lines)
        parents, profiles, features = parse_directives_and_features(body)
        if not parents:
            continue
        parent = parents[0]
        parent_chain_feats = resolve_parent_chain_features(name, files)

        new_body = []
        changed = False
        for l in body:
            s = l.strip()
            if s.startswith("@profile:"):
                prof = s.split(":", 1)[1].strip()
                if prof == parent:
                    # redundant, drop it
                    changed = True
                    continue
            # remove features already provided by parent chain
            if s and not s.startswith("#") and not s.startswith("@"):
                if s in parent_chain_feats:
                    changed = True
                    continue
            new_body.append(l)

        if changed:
            new_lines = lines[:first+1] + new_body + lines[last:]
            write_profile(path, new_lines)
            modified.append(name)
            print(f"Updated {name}")

    if modified:
        print("Modified profiles:", ", ".join(modified))
    else:
        print("No changes made")


if __name__ == '__main__':
    main()
