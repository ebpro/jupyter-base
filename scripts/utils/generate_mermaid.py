#!/usr/bin/env python3
"""
Generate a Mermaid diagram showing profiles and their included features.

Usage:
  python scripts/utils/generate_mermaid.py --out docs/diagrams/features-profiles.mmd

The script scans `generated/profiles/` for profile entries and `features/` for feature folders.
It attempts to detect feature references inside profile files (searching for feature names), and
looks for explicit parent declarations using `@parent` or `parent:` patterns inside profile files.

The output is a Mermaid `flowchart LR` file which GitHub can render natively.
"""

from pathlib import Path
import argparse
import re
import sys

# Canonical per-profile feature source (bundle expansion + @parent resolution).
# Guarded so the script still runs even if the `solen` package is not importable;
# in that case we fall back to the naive text scan below.
try:
    from solen.generators.readme import collect_profile_features
except Exception:
    collect_profile_features = None


def sanitize_id(s: str) -> str:
    return re.sub(r"[^0-9A-Za-z_]+", "_", s)


def find_features(repo_root: Path) -> list:
    features_dir = repo_root / "features"
    if not features_dir.exists():
        return []
    return sorted([p.name for p in features_dir.iterdir() if p.is_dir()])


def scan_profile_for_features(profile_path: Path, feature_names: list) -> tuple[list, str]:
    """
    Return (features_found_list, parent_profile_or_empty_str).

    Accept either a profile directory (legacy) or a profile *file* which is a
    plain text list of features (one per line). The function searches the file
    contents for feature names and optional parent declarations like ``@parent`` or ``parent:``.
    """
    found = set()
    parent = None
    parent_re = re.compile(r"@parent\s*[:=]?\s*(\S+)|parent\s*[:=]\s*(\S+)", re.IGNORECASE)

    if profile_path.is_file():
        try:
            txt = profile_path.read_text(encoding="utf-8")
        except Exception:
            txt = ""
        m = parent_re.search(txt)
        if m:
            parent = (m.group(1) or m.group(2) or "").strip()
        for feat in feature_names:
            if re.search(rf"\b{re.escape(feat)}\b", txt):
                found.add(feat)
        # also try line-based feature names (common profile file format)
        for line in txt.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line in feature_names:
                found.add(line)

    elif profile_path.is_dir():
        # original behavior: scan files under the profile directory
        for f in profile_path.rglob("*"):
            if not f.is_file():
                continue
            try:
                txt = f.read_text(encoding="utf-8")
            except Exception:
                continue
            m = parent_re.search(txt)
            if m:
                parent = (m.group(1) or m.group(2) or "").strip()
            for feat in feature_names:
                if re.search(rf"\b{re.escape(feat)}\b", txt):
                    found.add(feat)

        # fallback: treat subdirs or filenames as explicit feature names if they match
        if not found:
            for child in profile_path.iterdir():
                name = child.name
                if name in feature_names:
                    found.add(name)

    return sorted(found), (parent or "")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default="docs/diagrams/features-profiles.mmd")
    args = p.parse_args()

    repo_root = Path.cwd()
    profiles_dir = repo_root / "generated" / "profiles"
    out_path = repo_root / args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)

    feature_names = find_features(repo_root)

    # Canonical per-profile feature source: expands bundles to their leaf features
    # and resolves @parent. Keyed by profile name (file stem). Computed once.
    canonical_features = None
    if collect_profile_features is not None:
        try:
            canonical_features = collect_profile_features(repo_root)
        except Exception:
            canonical_features = None

    profiles = []
    if profiles_dir.exists():
        # Profiles in this repo are stored as profile files (plain text lists) rather
        # than subdirectories. Accept either files or directories for compatibility.
        # Skip dotfiles (e.g. the tracked `generated/profiles/.gitkeep`) and README.md,
        # matching the canonical collector in solen.generators.readme.
        entries = sorted(
            (p for p in profiles_dir.iterdir()
             if not p.name.startswith(".") and p.name != "README.md"),
            key=lambda x: x.name,
        )
        for entry in entries:
            if entry.is_dir() or entry.is_file():
                # @parent edge detection stays as-is: it reads `@parent:` from the
                # profile file text.
                _naive_feats, parent = scan_profile_for_features(entry, feature_names)
                if canonical_features is not None and entry.name in canonical_features:
                    # Use the expanded (leaf) feature set from the canonical collector.
                    feats = sorted(canonical_features[entry.name][1])
                else:
                    # Fallback: naive text scan (e.g. `solen` not importable).
                    feats = _naive_feats
                profiles.append({"name": entry.name, "path": str(entry), "features": feats, "parent": parent})

    lines = []
    lines.append("flowchart LR")
    lines.append("%% Auto-generated by scripts/utils/generate_mermaid.py")

    # create profile nodes and clusters
    for prof in profiles:
        pid = "profile_" + sanitize_id(prof["name"])  # e.g., profile_quarto_full
        # explicit profile node
        lines.append(f'{pid}["{prof["name"]}"]')
        # cluster for features (optional)
        if prof["features"]:
            cluster_id = "cluster_" + sanitize_id(prof["name"]) 
            lines.append(f'subgraph {cluster_id} ["{prof["name"]} features"]')
            for feat in prof["features"]:
                fid = "feat_" + sanitize_id(feat)
                lines.append(f'  {fid}["{feat}"]')
            lines.append('end')
            # Features are grouped under the profile's subgraph above; the subgraph
            # label ("<profile> features") conveys membership, so no redundant
            # explicit profile->feature edges are emitted (keeping the profile node
            # the single "profile_*" anchor per profile).

    # parent edges
    for prof in profiles:
        if prof.get("parent"):
            parent_name = prof["parent"].strip()
            # parent may be a relative name; try to find matching profile
            matches = [p for p in profiles if p["name"] == parent_name]
            if matches:
                child_id = "profile_" + sanitize_id(prof["name"]) 
                parent_id = "profile_" + sanitize_id(parent_name)
                lines.append(f'{child_id} --> {parent_id}')

    if not profiles:
        lines.append('%% No profiles found under `generated/profiles/`.')
        if not feature_names:
            lines.append('%% No features found under `features/`.')

    out_path.write_text("\n".join(lines), encoding="utf-8")
    # Emit the flowchart on stdout (so it can be piped to a Mermaid renderer) and
    # keep the human-readable status message on stderr.
    print("\n".join(lines))
    print(f"Wrote Mermaid diagram: {out_path}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(1)
