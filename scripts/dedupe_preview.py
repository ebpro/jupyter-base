#!/usr/bin/env python3
"""
Simple dedupe preview: prints features in each profile that are already provided
by its parent/profile chain. Safe to run in repo root.
"""
import os
from collections import deque

P_DIR = 'profiles'

# Read profiles
profiles = {}
for fn in sorted(os.listdir(P_DIR)):
    path = os.path.join(P_DIR, fn)
    if not os.path.isfile(path):
        continue
    with open(path, 'r', encoding='utf-8') as f:
        lines = [ln.strip() for ln in f if ln.strip() and not ln.strip().startswith('#')]
    profiles[fn] = lines

# Helper: find profile file by token (either exact filename or suffix match)
def find_profile_by_token(token):
    if token in profiles:
        return token
    for k in profiles:
        if k.endswith(token):
            return k
    return None

# Given a profile filename, compute provided features by traversing @profile/@parent refs
def get_provided(profile_name):
    provided = set()
    q = deque()
    lines = profiles.get(profile_name, [])
    for l in lines:
        if l.startswith('@'):
            q.append(l.split(':',1)[1])
    visited = set()
    while q:
        ref = q.popleft()
        if ref in visited:
            continue
        visited.add(ref)
        matched = find_profile_by_token(ref)
        if not matched:
            # unknown reference, skip
            continue
        ref_lines = profiles.get(matched, [])
        for rl in ref_lines:
            if rl.startswith('@'):
                q.append(rl.split(':',1)[1])
            else:
                provided.add(rl)
    return provided

# Scan for duplicates
duplicates_found = False
for p in sorted(profiles):
    provided = get_provided(p)
    dup = [l for l in profiles[p] if not l.startswith('@') and l in provided]
    if dup:
        duplicates_found = True
        print(f"Profile {p} duplicates: {dup}")

if not duplicates_found:
    print('No duplicates found')
