#!/usr/bin/env python3
"""
Infer @parent directives from numeric hierarchical prefixes and apply changes.
Usage: scripts/infer_parents_from_prefixes.py [--apply]
- without --apply prints planned edits
- with --apply writes files

Rules:
- For a profile named 'AA-BB-name' (three-part), parent is searched as:
  1) any profile starting with 'AA-00-'
  2) or 'AA-base' or 'AA-00base' fallback
- If parent found and profile lacks '@parent:' directive, insert '@parent:parentfilename' after the top comment block (or at top).
- Remove any '@profile:' lines that refer to the same parent (duplicate composition)
"""
import os,sys,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
P_DIR=ROOT/"profiles"

profiles=[p.name for p in sorted(P_DIR.iterdir()) if p.is_file()]

# helper to find parent candidate for a profile name
def find_parent(profile_name, all_profiles):
    # split tokens
    parts=profile_name.split('-',2)
    if len(parts)<3:
        return None
    aa=parts[0]
    # look for AA-00-*
    for ap in all_profiles:
        if ap.startswith(f"{aa}-00-"):
            return ap
    # look for AA-base
    for ap in all_profiles:
        if ap.startswith(f"{aa}-base") or ap==f"{aa}-base":
            return ap
    return None

plans=[]
for p in profiles:
    parent=find_parent(p,profiles)
    if not parent:
        continue
    path=P_DIR/p
    txt=path.read_text(encoding='utf-8')
    lines=[l.rstrip('\n') for l in txt.splitlines()]
    has_parent=False
    for l in lines:
        if l.strip().startswith('@parent:'):
            has_parent=True
            break
    if has_parent:
        continue
    # determine insertion point: after first non-empty comment block (lines starting with #)
    insert_idx=0
    # skip initial blank lines
    i=0
    while i<len(lines) and lines[i].strip()=="":
        i+=1
    # if next line is a comment, include comment block
    if i<len(lines) and lines[i].lstrip().startswith('#'):
        # include subsequent comment lines
        j=i
        while j<len(lines) and lines[j].lstrip().startswith('#'):
            j+=1
        insert_idx=j
    else:
        insert_idx=i
    # prepare new content: add @parent line
    new_lines = lines[:insert_idx] + [f"@parent:{parent}"] + lines[insert_idx:]
    # also remove any @profile:parent or @profile:<suffix> that equals parent
    new_lines2=[]
    parent_suffix=parent
    if '-' in parent:
        suffix=parent.split('-',2)[-1]
    else:
        suffix=parent
    for l in new_lines:
        if l.strip().startswith('@profile:'):
            ref=l.split(':',1)[1].strip()
            if ref==parent or ref==suffix:
                # skip redundant
                continue
        new_lines2.append(l)
    plans.append((p,parent,lines,new_lines2))

if not plans:
    print('No inferred parent insertions required')
    sys.exit(0)

# print plan
print('Planned changes:')
for p,parent,old,new in plans:
    print(f"- {p}: add @parent:{parent} (and remove redundant @profile if present)")

if '--apply' not in sys.argv:
    print('\nRun with --apply to write these changes')
    sys.exit(0)

# apply changes
for p,parent,old,new in plans:
    path=P_DIR/p
    path.write_text('\n'.join(new)+"\n",encoding='utf-8')
    print(f'Applied changes to {p}')

print('Done. Please run ./scripts/validate-profiles.sh to verify')
