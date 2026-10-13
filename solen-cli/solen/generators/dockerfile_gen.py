from __future__ import annotations

import base64
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from jinja2 import Environment, FileSystemLoader

from solen.core.feature import (
    collect_feature_metadata,
    collect_feature_options,
    collect_post_install_checks,
    expand_feature_dependencies,
    topological_sort_features,
)
from solen.core.profile import find_profile, is_profile_file, parse_profile


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


def read_parent_name(profile_path: Path) -> str | None:
    """Return the direct `@parent:` name declared in a profile file, or None.

    Reads only the profile's own file (does not resolve the chain).
    """
    with open(profile_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("@parent:"):
                return line.split(":", 1)[1].strip()
    return None


def compute_install_features(
    features_dir: Path,
    all_expanded: list[str] | set[str],
    parent_expanded: list[str] | set[str] | None,
) -> list[str]:
    """Topologically-ordered features to install in THIS stage.

    With a parent: only the delta (all_expanded minus the ancestor's expanded
    set), sorted before the topological sort for a deterministic install order.
    Without a parent: the full set, exactly as before (byte-identical output).
    """
    if parent_expanded is None:
        return topological_sort_features(features_dir, list(all_expanded))
    delta = set(all_expanded) - set(parent_expanded)
    return topological_sort_features(features_dir, sorted(delta))


def build_profile_data(repo_root: Path, profile_name: str) -> dict[str, Any]:
    profile_path = find_profile(profile_name, repo_root)
    profiles_dir = repo_root / "profiles"
    profile_data = parse_profile(profile_path, profiles_dir)

    features_dir = repo_root / "features"
    expanded = expand_feature_dependencies(features_dir, profile_data.features)
    features = topological_sort_features(features_dir, expanded)

    parent_name = read_parent_name(profile_path)
    if parent_name is not None:
        parent_data = parse_profile(find_profile(parent_name, repo_root), profiles_dir)
        parent_expanded = expand_feature_dependencies(features_dir, parent_data.features)
        install_features = compute_install_features(features_dir, expanded, parent_expanded)
        from_stage = f"final-{parent_name}"
    else:
        install_features = features
        from_stage = "base"

    metadata = collect_feature_metadata(features_dir, features)
    feature_options = collect_feature_options(features_dir, features)
    checks = collect_post_install_checks(features_dir, features)
    all_options = {**feature_options, **profile_data.options}

    return {
        "name": profile_name,
        "features": features,
        "features_str": " ".join(features) if features else "none",
        "provides_str": ",".join(metadata.get("provides", [])),
        "env": {k: docker_escape(v) for k, v in all_options.items()},
        "checks": [
            {
                **check,
                "command_b64": base64.b64encode(check["command"].encode("utf-8")).decode("ascii"),
            }
            for check in checks
        ],
        "install_features": install_features,
        "from_stage": from_stage,
        "parent": parent_name,
    }


def order_profiles_parent_first(
    profile_names: set[str] | list[str],
    parents: Mapping[str, str | None],
) -> list[str]:
    """Order profiles so every profile appears after its parent.

    Profiles are visited in alphabetical order; visiting one emits its
    not-yet-emitted ancestor chain first (root-most first), then the profile
    itself. Parentless profiles therefore keep their exact alphabetical
    position, and only a parent pulled forward towards an alphabetically
    earlier child moves -- minimising churn versus plain ``sorted()``.
    Deterministic and independent of filesystem iteration order.

    Fails loudly (``ValueError``) on a parent cycle or on a parent that is
    not part of the set: silently dropping or looping stages would emit a
    Dockerfile with a dangling ``FROM`` alias that BuildKit rejects, so the
    misconfiguration must surface at generation time.
    """
    ordered: list[str] = []
    emitted: set[str] = set()

    for name in sorted(profile_names):
        chain: list[str] = []
        seen: set[str] = set()
        node: str | None = name
        while node is not None and node not in emitted:
            if node in seen:
                raise ValueError(
                    f"parent cycle detected involving profile '{node}': "
                    + " -> ".join(chain + [node])
                )
            if node not in parents:
                raise ValueError(
                    f"unknown parent '{node}' referenced while ordering profile '{name}'"
                )
            seen.add(node)
            chain.append(node)
            node = parents[node]
        for item in reversed(chain):
            emitted.add(item)
            ordered.append(item)

    return ordered


def _parent_chain_root_first(repo_root: Path, profile_name: str) -> list[str]:
    """Return ``profile_name`` and its ancestors, root-most parent first.

    A parented profile renders ``FROM final-<parent>``, so the ancestor
    stages must be emitted as well -- otherwise the alias dangles. Raises
    ``ValueError`` on a parent cycle.
    """
    chain: list[str] = []
    seen: set[str] = set()
    node: str | None = profile_name
    while node is not None:
        if node in seen:
            raise ValueError(
                f"parent cycle detected involving profile '{node}': "
                + " -> ".join(chain + [node])
            )
        seen.add(node)
        chain.append(node)
        node = read_parent_name(find_profile(node, repo_root))
    return list(reversed(chain))


def generate_single_profile_dockerfile(
    repo_root: Path,
    profile_name: str,
    output_path: Path,
) -> None:
    # Emit the parent chain (root-most first) so a declared
    # ``FROM final-<parent>`` alias resolves; parentless profiles render
    # exactly one profile, byte-identical to the previous behaviour.
    profiles_data = [
        build_profile_data(repo_root, name)
        for name in _parent_chain_root_first(repo_root, profile_name)
    ]
    dockerfile_text = render_template(repo_root, profiles_data)

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
    (generated_dir / ".gitkeep").touch()

    if matrix_dir.exists():
        for m in matrix_dir.glob("*.y*ml"):
            generate_profiles(m, generated_dir, prefix="")

    profile_names = {
        p.name
        for d in (profiles_dir, generated_dir)
        if d.exists()
        for p in d.iterdir()
        if is_profile_file(p)
    }

    # Build the data in alphabetical order (deterministic), then emit the
    # stages parent-before-child so every internal ``FROM <alias>`` refers to
    # an already-defined stage (BuildKit requires the definition to precede
    # the reference).
    data_by_name = {name: build_profile_data(repo_root, name) for name in sorted(profile_names)}
    ordered_names = order_profiles_parent_first(
        profile_names, {name: data["parent"] for name, data in data_by_name.items()}
    )
    profiles_data = [data_by_name[name] for name in ordered_names]

    dockerfile_text = render_template(repo_root, profiles_data)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(dockerfile_text, encoding="utf-8")

    return ordered_names
