from __future__ import annotations

from pathlib import Path
from typing import TextIO, Any

from jinja2 import Environment, FileSystemLoader

from solen.core.feature import (
    collect_feature_metadata,
    collect_feature_options,
    expand_feature_dependencies,
    topological_sort_features,
)
from solen.core.profile import find_profile, parse_profile


def docker_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def render_template(repo_root: Path, profiles: list[dict[str, Any]]) -> str:
    env = Environment(
        loader=FileSystemLoader(repo_root / "solen-cli" / "solen" / "generators"),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    template = env.get_template("dockerfile_template.j2")

    toolcache_exists = (repo_root / "generated" / "toolcache").exists()

    return template.render(
        profiles=profiles,
        toolcache_exists=toolcache_exists,
    )


def build_profile_data(repo_root: Path, profile_name: str) -> dict[str, Any]:
    profile_path = find_profile(profile_name, repo_root)
    profiles_dir = repo_root / "profiles"
    profile_data = parse_profile(profile_path, profiles_dir)

    features_dir = repo_root / "features"
    expanded = expand_feature_dependencies(features_dir, profile_data.features)
    features = topological_sort_features(features_dir, expanded)

    metadata = collect_feature_metadata(features_dir, features)
    feature_options = collect_feature_options(features_dir, features)
    all_options = {**feature_options, **profile_data.options}

    return {
        "name": profile_name,
        "features": features,
        "features_str": " ".join(features) if features else "none",
        "provides_str": ",".join(metadata.get("provides", [])),
        "env": {k: docker_escape(v) for k, v in all_options.items()},
    }


def generate_single_profile_dockerfile(
    repo_root: Path,
    profile_name: str,
    output_path: Path,
) -> None:
    profile_data = build_profile_data(repo_root, profile_name)
    dockerfile_text = render_template(repo_root, [profile_data])

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(dockerfile_text, encoding="utf-8")


def generate_multi_profile_dockerfile(
    repo_root: Path,
    output_path: Path,
) -> list[str]:
    from solen.generators.profiles import generate_profiles

    profiles_dir = repo_root / "profiles"
    generated_dir = repo_root / "generated" / "profiles"
    matrix_dir = profiles_dir / "matrix"

    if generated_dir.exists():
        import shutil
        shutil.rmtree(generated_dir)
    generated_dir.mkdir(parents=True, exist_ok=True)

    if matrix_dir.exists():
        for m in matrix_dir.glob("*.y*ml"):
            generate_profiles(m, generated_dir, prefix="")

    profile_names = {
        p.name
        for d in (profiles_dir, generated_dir)
        if d.exists()
        for p in d.iterdir()
        if p.is_file() and p.name not in {"README.md", "base"}
    }

    profiles_data = [build_profile_data(repo_root, n) for n in sorted(profile_names)]

    dockerfile_text = render_template(repo_root, profiles_data)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(dockerfile_text, encoding="utf-8")

    return sorted(profile_names)
