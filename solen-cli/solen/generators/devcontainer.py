"""Generate devcontainer.json (and docker-compose.yml) from profile metadata."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import yaml

from solen.core.profile import find_profile, parse_profile

DEFAULT_IMAGE_REPO = "ghcr.io/ebpro"
DEFAULT_IMAGE_NAME = "solen"


def parse_service_specs(raw_services: list[str]) -> list[dict[str, Any]]:
    """Parse '@services:' entries of the form name:key=value,key2=value2."""
    services: list[dict[str, Any]] = []
    for raw in raw_services:
        name, _, opts = raw.partition(":")
        options: dict[str, str] = {}
        if opts:
            for pair in opts.split(","):
                key, _, value = pair.partition("=")
                options[key.strip()] = value.strip()
        services.append({"name": name.strip(), "options": options})
    return services


def collect_vscode_metadata(features_dir: Path, features: list[str]) -> dict[str, Any]:
    """Collect VS Code extensions, settings, and forward ports from features.

    Dependencies are expanded recursively (dependencies first); entries are
    deduplicated while preserving order.
    """
    extensions: list[str] = []
    settings: dict[str, Any] = {}
    forward_ports: list[Any] = []
    ordered: list[str] = []
    seen: set[str] = set()

    def visit(feature: str) -> None:
        if feature in seen:
            return
        feature_json = features_dir / feature / "feature.json"
        if not feature_json.exists():
            return
        seen.add(feature)
        try:
            metadata = json.loads(feature_json.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return
        for dep in metadata.get("dependsOn", []):
            visit(dep)
        ordered.append(feature)

    for feature in features:
        visit(feature)

    for feature in ordered:
        feature_json = features_dir / feature / "feature.json"
        try:
            metadata = json.loads(feature_json.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        vscode = metadata.get("vscode") or {}
        for ext in vscode.get("extensions", []):
            if ext not in extensions:
                extensions.append(ext)
        settings.update(vscode.get("settings", {}))
        forward_ports.extend(vscode.get("forwardPorts", []))

    unique_ports: list[Any] = []
    for port in forward_ports:
        if port not in unique_ports:
            unique_ports.append(port)

    return {
        "extensions": extensions,
        "settings": settings,
        "forwardPorts": unique_ports,
    }


def build_image_ref(image_tag: str) -> str:
    """Build the overridable image reference used in devcontainer files."""
    return (
        f"${{IMAGE_REPO:-{DEFAULT_IMAGE_REPO}}}/${{IMAGE_NAME:-{DEFAULT_IMAGE_NAME}}}"
        f":${{IMAGE_TAG:-{image_tag}}}"
    )


def build_devcontainer_config(
    profile_name: str,
    vscode_metadata: dict[str, Any],
    image_ref: str,
    has_services: bool,
) -> dict[str, Any]:
    """Build the devcontainer.json structure for a profile."""
    config: dict[str, Any] = {
        "name": f"Solen - {profile_name.replace('-', ' ').title()}",
        "workspaceFolder": "/home/jovyan/work/local",
        "remoteUser": "jovyan",
    }

    if has_services:
        config["dockerComposeFile"] = ["docker-compose.yml"]
        config["service"] = "devcontainer"
    else:
        config["image"] = image_ref

    config["customizations"] = {
        "vscode": {
            "extensions": vscode_metadata["extensions"],
            "settings": {
                "terminal.integrated.defaultProfile.linux": "zsh",
                "terminal.integrated.profiles.linux": {
                    "zsh": {"path": "/bin/zsh", "args": ["-l"]}
                },
                "files.watcherExclude": {
                    "**/.git/objects/**": True,
                    "**/node_modules/**": True,
                    "**/.venv/**": True,
                    "**/__pycache__/**": True,
                },
                "editor.formatOnSave": True,
                **vscode_metadata["settings"],
            },
        }
    }

    config["forwardPorts"] = vscode_metadata["forwardPorts"]
    config["postStartCommand"] = f"echo 'Dev environment ready: {profile_name}'"
    config["features"] = {}
    config["remoteEnv"] = {"DOCKER_BUILDKIT": "1"}

    return config


def build_docker_compose(
    profile_name: str,
    services: list[dict[str, Any]],
    image_ref: str,
    templates_dir: Path,
) -> dict[str, Any]:
    """Build docker-compose.yml structure from profile services and templates."""
    compose: dict[str, Any] = {
        "services": {},
        "volumes": {},
        "networks": {"notebooknet": None},
    }

    service_dependencies: list[dict[str, str]] = []

    for service in services:
        template_file = templates_dir / f"{service['name']}.yml"
        if not template_file.exists():
            print(f"Warning: service template not found: {template_file}")
            continue

        with open(template_file, encoding="utf-8") as f:
            service_config = yaml.safe_load(f)

        service_name = list(service_config.keys())[0]
        compose["services"][service_name] = service_config[service_name]

        service_dependencies.append({
            "name": service_name,
            "condition": (
                "service_healthy" if "healthcheck" in service_config[service_name]
                else "service_started"
            ),
        })

        for volume_mount in service_config[service_name].get("volumes", []):
            if isinstance(volume_mount, str) and ":" in volume_mount:
                vol_name = volume_mount.split(":")[0]
                if not vol_name.startswith("/") and not vol_name.startswith("."):
                    compose["volumes"][vol_name] = None

    depends_on = {
        dep["name"]: {"condition": dep["condition"]} for dep in service_dependencies
    }

    env: dict[str, str] = {
        "DB_USERNAME": "${DB_USERNAME:-dba}",
        "DB_PASSWORD": "${DB_PASSWORD:-secretsecret}",
        "DB_NAME": "${DB_NAME:-notebook-db}",
    }

    service_names = {s["name"] for s in services}
    if "dind" in service_names:
        env.update({
            "DOCKER_HOST": "tcp://docker:2376",
            "DOCKER_CERT_PATH": "/certs/client",
            "DOCKER_TLS_CERTDIR": "/certs",
            "DOCKER_TLS_VERIFY": "1",
        })

    if "postgres" in service_names:
        env["DB_URL"] = (
            "postgresql://${DB_USERNAME:-dba}:${DB_PASSWORD:-secretsecret}"
            "@postgres:5432/${DB_NAME:-notebook-db}"
        )
    elif "mysql" in service_names:
        env["DB_URL"] = "jdbc:mysql://mysql:3306/${DB_NAME:-notebook-db}"

    volumes = [
        "${PWD}:/home/jovyan/work/local",
        "jupyter-work:/home/jovyan/work/",
    ]
    if "dind" in service_names:
        volumes.append("certs-client:/certs/client:ro")

    compose["services"]["devcontainer"] = {
        "image": image_ref,
        "user": "jovyan",
        "environment": env,
        "volumes": volumes,
        "networks": ["notebooknet"],
        "depends_on": depends_on,
        "command": "sleep infinity",
    }

    compose["volumes"]["jupyter-work"] = None

    return compose


def generate_devcontainer(repo_root: Path, profile_name: str, output_dir: Path) -> Path:
    """Generate devcontainer.json (and docker-compose.yml when services exist).

    Writes to ``output_dir/<profile>/devcontainer.json`` and returns the path.
    """
    profile_path = find_profile(profile_name, repo_root)
    data = parse_profile(profile_path, profile_path.parent)

    features_dir = repo_root / "features"
    templates_dir = repo_root / "devcontainer" / "service-templates"

    services = parse_service_specs(data.services)
    vscode_metadata = collect_vscode_metadata(features_dir, data.features)
    image_ref = build_image_ref(profile_name)

    out_dir = output_dir / profile_name
    out_dir.mkdir(parents=True, exist_ok=True)

    config = build_devcontainer_config(
        profile_name, vscode_metadata, image_ref, has_services=bool(services)
    )
    json_path = out_dir / "devcontainer.json"
    json_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    if services:
        compose = build_docker_compose(profile_name, services, image_ref, templates_dir)
        compose_path = out_dir / "docker-compose.yml"
        compose_path.write_text(
            yaml.dump(compose, default_flow_style=False, sort_keys=False),
            encoding="utf-8",
        )

    return json_path


def list_generated_profiles(repo_root: Path) -> list[str]:
    """List profile names available under generated/profiles/ or profiles/."""
    for base in (repo_root / "generated" / "profiles", repo_root / "profiles"):
        if not base.is_dir():
            continue
        names = sorted(
            p.stem for p in base.iterdir()
            if p.is_file() and not p.name.startswith(".") and p.name != "README.md"
        )
        if names:
            return names
    return []
