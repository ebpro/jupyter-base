"""Profile generator - creates profile files from YAML matrix definitions."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


def _collect_feature_names_from_matrix(data: dict[str, Any]) -> set[str]:
    """Collect all feature-like names referenced in a matrix YAML structure."""
    names: set[str] = set()
    # top-level features
    for f in data.get("features", []) or []:
        names.add(f)

    # matrix entries
    for entry in (data.get("matrix", {}) or {}).values():
        if not entry:
            continue
        if isinstance(entry, dict):
            for f in entry.get("features", []) or []:
                names.add(f)
            # Do NOT treat `services` entries as feature references; they are
            # service tokens (e.g., 'postgres:version=16') and not feature dirs.
    return names


def validate_matrix_features(matrix_path: Path, repo_root: Path) -> list[str]:
    """Validate that feature names referenced in the matrix exist under `features/`.

    Returns a list of missing feature names (empty if all present).
    """
    if not matrix_path.exists():
        raise FileNotFoundError(f"Matrix file not found: {matrix_path}")

    with open(matrix_path, encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    refs = _collect_feature_names_from_matrix(data)
    missing: list[str] = []
    features_dir = repo_root / "features"
    for name in sorted(refs):
        if not name:
            continue
        # ignore common service names that are not feature dirs (e.g., dind, k3s)
        # but still check for corresponding feature presence
        if not (features_dir / name).exists():
            missing.append(name)
    return missing


def render_options(opts: dict[str, Any]) -> str:
    """Render options dictionary as key=value pairs."""
    pairs = [f"{k}={v}" for k, v in opts.items()]
    return ";".join(pairs)


def generate_profile_file(
    profile_spec: dict[str, Any],
    out_dir: Path,
    prefix: str = "",
    source: str | None = None,
) -> list[str]:
    """Generate profile files from a profile specification.

    Args:
        profile_spec: Profile specification with base, parent, labels, features
        out_dir: Output directory for generated profiles
        prefix: Optional prefix for profile filenames

    Returns:
        List of created profile file paths
    """
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
            # Add traceability: include originating matrix/source and any
            # top-level comment from the profile spec.
            if source:
                f.write(f"# Source matrix: {source}\n")
                # Traceability: source matrix and label
                f.write(f"# Matrix label: {label}\n")
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
                    # Emit options both as comments for traceability and as
                    # @options entries consumed by other tooling.
                    opts_line = render_options(options)
                    f.write(f"# Matrix options: {opts_line}\n")
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


def generate_profiles(matrix_path: Path, out_dir: Path, prefix: str = "") -> int:
    """Generate profiles from a YAML matrix file.

    Args:
        matrix_path: Path to YAML matrix file
        out_dir: Output directory for generated profiles
        prefix: Optional prefix for profile filenames

    Returns:
        Number of profiles generated
    """
    if not matrix_path.exists():
        raise FileNotFoundError(f"Matrix file not found: {matrix_path}")

    # Load YAML matrix
    with open(matrix_path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if not data:
        # Empty or comment-only matrix files are allowed (e.g., placeholders
        # for merged matrices). Do not treat as an error; simply generate
        # zero profiles from this file.
        return 0

    created_files = []

    # New-style: top-level 'profiles' list
    if "profiles" in data:
        for spec in data.get("profiles", []):
            created = generate_profile_file(spec, out_dir, prefix=prefix, source=str(matrix_path))
            created_files.extend(created)

    # Legacy/simple style: top-level 'parent' + 'matrix' mapping
    elif "matrix" in data:
        parent = data.get("parent", "")
        # Derive base name if not provided
        base = data.get("base")
        if not base and parent:
            base = parent.replace("-00-", "-01-")
            if base.endswith("-sdk"):
                base = base[: -len("-sdk")]

        comment = data.get("comment", "")
        features = data.get("features", [])
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

            # Use the derived base as the profile base
            profile_base = base if base else label
            profile_spec = {
                "base": profile_base,
                "parent": parent,
                "comment": comment,
                "labels": {label: variant_spec},
                "features": features
            }
            created = generate_profile_file(profile_spec, out_dir, prefix=prefix, source=str(matrix_path))
            created_files.extend(created)
    else:
        raise ValueError("No profiles or matrix entries found in matrix file")

    return len(created_files)
