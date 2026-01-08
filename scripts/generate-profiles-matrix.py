#!/usr/bin/env python3
"""
generate-profiles-matrix.py

Reads a simple JSON matrix spec and emits concrete profile files
into a target directory (default: generated/profiles).

Usage:
  ./scripts/generate-profiles-matrix.py --matrix profiles/matrix.json --out generated/profiles --prefix ''

The matrix JSON format:
{
  "profiles": [
    {
      "base": "11-01-dev-java",
      "parent": "11-00-dev-java-sdk",
      "comment": "Java developer profile",
      "labels": {
        "latest": {"JDK_VERSION": "latest"},
        "ea": {"JDK_VERSION":"ea"},
        "8": {"JDK_VERSION":"8"}
      }
    }
  ]
}
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def render_options(opts: dict) -> str:
    pairs = []
    for k, v in opts.items():
        pairs.append(f"{k}={v}")
    return ";".join(pairs)


def generate(profile_spec: dict, out_dir: Path, prefix: str = "") -> list[str]:
    created = []
    base = profile_spec["base"]
    parent = profile_spec.get("parent", "")
    comment = profile_spec.get("comment", "")
    labels = profile_spec.get("labels", {})
    features = profile_spec.get("features", [])

    for label, opts in labels.items():
        # Avoid duplicate names when base already ends with the label
        if base == label or base.endswith(f"-{label}"):
            name = base
        else:
            name = f"{base}-{label}"
        if prefix:
            name = f"{prefix}{name}"

        out_path = out_dir / name
        out_dir.mkdir(parents=True, exist_ok=True)

        # Build feature list: base features + variant-specific features
        all_features = features.copy()
        if isinstance(opts, dict) and "features" in opts:
            all_features.extend(opts["features"])

        with open(out_path, "w", encoding="utf-8") as f:
            if comment:
                f.write(f"# {comment}\n\n")
            if parent:
                f.write(f"@parent:{parent}\n\n")
            # Emit feature lines
            for feat in all_features:
                f.write(f"{feat}\n")
            if all_features:
                f.write("\n")

            # Write @options lines
            if isinstance(opts, dict) and "options" in opts:
                options = opts["options"]
                if options:
                    opts_line = render_options(options)
                    f.write(f"@options:{opts_line}\n")
                    f.write("\n")

            # Write @services lines
            if isinstance(opts, dict) and "services" in opts:
                services = opts["services"]
                if services:
                    for svc in services:
                        f.write(f"@services:{svc}\n")

        created.append(str(out_path))

    return created


def main(argv: list[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    p = argparse.ArgumentParser(description="Generate concrete profiles from a matrix JSON spec")
    p.add_argument("--matrix", default="profiles/matrix.json", help="Path to matrix JSON file")
    p.add_argument("--out", default="generated/profiles", help="Output directory for generated profiles")
    p.add_argument("--prefix", default="", help="Optional filename prefix for generated profiles")
    args = p.parse_args(argv)

    matrix_path = Path(args.matrix)
    out_dir = Path(args.out)

    if not matrix_path.exists():
        print(f"Matrix file not found: {matrix_path}")
        return 2

    # Support JSON or YAML matrix files. If YAML is requested and PyYAML is
    # not installed, instruct the user to install it.
    try:
        text = matrix_path.read_text(encoding="utf-8")
        if matrix_path.suffix in (".yaml", ".yml"):
            try:
                import yaml  # type: ignore
            except Exception:
                print("Matrix is YAML but PyYAML is not installed. Install with: pip install pyyaml", file=sys.stderr)
                return 4
            data = yaml.safe_load(text)
        else:
            print("Only YAML matrix files are supported. Rename your matrix to .yaml or .yml", file=sys.stderr)
            return 5
    except Exception as e:
        print(f"Failed to read matrix file: {e}")
        return 3

    created_files = []

    # New-style: top-level 'profiles' list
    if "profiles" in data:
        for spec in data.get("profiles", []):
            created = generate(spec, out_dir, prefix=args.prefix)
            created_files.extend(created)
    # Legacy/simple style: top-level 'parent' + 'matrix' mapping
    elif "matrix" in data:
        parent = data.get("parent", "")
        # Derive base name if not provided: replace '-00-' with '-01-' and strip trailing '-sdk'
        base = data.get("base")
        if not base and parent:
            base = parent.replace("-00-", "-01-")
            if base.endswith("-sdk"):
                base = base[: -len("-sdk")]

        comment = data.get("comment", "")
        features = data.get("features", [])
        # Top-level options applied to all labels (label-specific options override)
        top_opts = data.get("options", {}) if isinstance(data.get("options", {}), dict) else {}
        labels = data.get("matrix", {})
        for label, spec in labels.items():
            # Support both simple dict format and nested structure
            if isinstance(spec, dict):
                label_opts = spec.get("options", {})
                label_features = spec.get("features", [])
                label_services = spec.get("services", [])
            else:
                label_opts = {}
                label_features = []
                label_services = []

            # Merge top-level options with label-specific options (label wins)
            merged_opts = dict(top_opts)
            merged_opts.update(label_opts)

            # Build variant spec with features and services
            variant_spec = {
                "options": merged_opts,
                "features": label_features,
                "services": label_services
            }

            # Use the derived base as the profile base; generate() will append the label.
            profile_base = base if base else label
            profile_spec = {
                "base": profile_base,
                "parent": parent,
                "comment": comment,
                "labels": {label: variant_spec},
                "features": features
            }
            created = generate(profile_spec, out_dir, prefix=args.prefix)
            created_files.extend(created)
    else:
        print("No profiles or matrix entries found in matrix file", file=sys.stderr)
        return 6

    print(f"Generated {len(created_files)} profiles in {out_dir}")
    for f in created_files:
        print(f" - {f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
