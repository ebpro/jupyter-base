#!/usr/bin/env python3
"""
Generate devcontainer.json and docker-compose.yml from profile and feature metadata.

Usage:
  scripts/generate-devcontainer-json.py <profile-name>

Reads:
  - profiles/<profile-name> (feature list and @services)
  - features/*/feature.json (vscode metadata)
  - devcontainer/service-templates/*.yml (service definitions)

Writes:
  - devcontainer/<profile-name>/devcontainer.json (generated)
  - devcontainer/<profile-name>/docker-compose.yml (generated)
"""

import json
import sys
import yaml
from pathlib import Path
from typing import Dict, List, Set, Tuple


def read_profile_features(profile_path: Path) -> Tuple[List[str], List[Dict]]:
    """Read feature list and services from profile file."""
    features = []
    services = []
    with open(profile_path) as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith('#'):
                continue
            # Parse @services lines
            if line.startswith('@services:'):
                service_def = line.split(':', 1)[1].strip()
                # Parse service:option=value,option2=value2
                if ':' in service_def:
                    name, opts = service_def.split(':', 1)
                    options = dict(opt.split('=') for opt in opts.split(','))
                    services.append({'name': name, 'options': options})
                else:
                    services.append({'name': service_def, 'options': {}})
            # Skip other @ directives
            elif line.startswith('@'):
                continue
            else:
                features.append(line)
    return features, services


def resolve_feature_deps(features_dir: Path, feature: str, resolved: Set[str]) -> List[str]:
    """Recursively resolve feature dependencies."""
    if feature in resolved:
        return []

    feature_json_path = features_dir / feature / "feature.json"
    if not feature_json_path.exists():
        return []

    with open(feature_json_path) as f:
        metadata = json.load(f)

    result = []
    # Resolve dependencies first
    for dep in metadata.get("dependsOn", []):
        result.extend(resolve_feature_deps(features_dir, dep, resolved))

    # Add this feature
    if feature not in resolved:
        result.append(feature)
        resolved.add(feature)

    return result


def collect_vscode_metadata(features_dir: Path, features: List[str]) -> Dict:
    """Collect VS Code extensions and settings from features."""
    extensions = []
    settings = {}
    forward_ports = []

    resolved_features = set()
    ordered_features = []
    for feature in features:
        ordered_features.extend(resolve_feature_deps(features_dir, feature, resolved_features))

    for feature in ordered_features:
        feature_json_path = features_dir / feature / "feature.json"
        if not feature_json_path.exists():
            continue

        with open(feature_json_path) as f:
            metadata = json.load(f)

        vscode = metadata.get("vscode", {})

        # Collect extensions (deduplicated)
        for ext in vscode.get("extensions", []):
            if ext not in extensions:
                extensions.append(ext)

        # Merge settings (later features override)
        settings.update(vscode.get("settings", {}))

        # Collect ports
        forward_ports.extend(vscode.get("forwardPorts", []))

    return {
        "extensions": extensions,
        "settings": settings,
        "forwardPorts": list(set(forward_ports))
    }


def generate_devcontainer_json(profile_name: str, vscode_metadata: Dict, image_tag: str, has_dind: bool) -> Dict:
    """Generate devcontainer.json structure."""
    compose_file = "docker-compose.yml" if has_dind else None

    config = {
        "name": f"Solen - {profile_name.replace('-', ' ').title()}",
        "workspaceFolder": "/home/jovyan/work/local",
        "remoteUser": "jovyan",
    }

    if compose_file:
        config["dockerComposeFile"] = [f"../../../generated/devcontainer/{profile_name}/{compose_file}"]
        config["service"] = "devcontainer"
    else:
        config["image"] = f"${{IMAGE_REPO:-ghcr.io/ebpro}}/${{IMAGE_NAME:-solen}}:${{IMAGE_TAG:-{image_tag}}}"

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
                    "**/__pycache__/**": True
                },
                "editor.formatOnSave": True,
                **vscode_metadata["settings"]
            }
        }
    }

    config["forwardPorts"] = vscode_metadata["forwardPorts"]
    config["postStartCommand"] = f"echo 'Dev environment ready: {profile_name}'"
    config["features"] = {}
    config["remoteEnv"] = {"DOCKER_BUILDKIT": "1"}

    return config


def generate_docker_compose(profile_name: str, services: List[Dict], image_tag: str, templates_dir: Path) -> Dict:
    """Generate docker-compose.yml structure from services."""
    compose = {
        "version": "3.8",
        "services": {},
        "volumes": {},
        "networks": {"notebooknet": None}
    }

    # Track volume dependencies
    service_dependencies = []

    # Load and merge service templates
    for service in services:
        template_file = templates_dir / f"{service['name']}.yml"
        if not template_file.exists():
            print(f"Warning: Service template not found: {template_file}")
            continue

        with open(template_file) as f:
            service_config = yaml.safe_load(f)

        # Merge service config
        service_name = list(service_config.keys())[0]
        compose["services"][service_name] = service_config[service_name]

        # Track dependencies for devcontainer
        service_dependencies.append({
            "name": service_name,
            "condition": "service_healthy" if "healthcheck" in service_config[service_name] else "service_started"
        })

        # Extract volumes from service
        for volume_mount in service_config[service_name].get("volumes", []):
            if isinstance(volume_mount, str) and ":" in volume_mount:
                vol_name = volume_mount.split(":")[0]
                # Only add named volumes (not bind mounts)
                if not vol_name.startswith("/") and not vol_name.startswith("."):
                    compose["volumes"][vol_name] = None

    # Add devcontainer service
    depends_on = {}
    for dep in service_dependencies:
        depends_on[dep["name"]] = {"condition": dep["condition"]}

    # Determine environment based on services
    env = {
        "DB_USERNAME": "${DB_USERNAME:-dba}",
        "DB_PASSWORD": "${DB_PASSWORD:-secretsecret}",
        "DB_NAME": "${DB_NAME:-notebook-db}",
    }

    # Add service-specific environment
    if any(s["name"] == "dind" for s in services):
        env.update({
            "DOCKER_HOST": "tcp://docker:2376",
            "DOCKER_CERT_PATH": "/certs/client",
            "DOCKER_TLS_CERTDIR": "/certs",
            "DOCKER_TLS_VERIFY": "1",
        })

    if any(s["name"] == "postgres" for s in services):
        env["DB_URL"] = "postgresql://${DB_USERNAME:-dba}:${DB_PASSWORD:-secretsecret}@postgres:5432/${DB_NAME:-notebook-db}"
    elif any(s["name"] == "mysql" for s in services):
        env["DB_URL"] = "jdbc:mysql://mysql:3306/${DB_NAME:-notebook-db}"

    # Build volumes list for devcontainer
    volumes = [
        "${PWD}:/home/jovyan/work/local",
        "jupyter-work:/home/jovyan/work/"
    ]

    if any(s["name"] == "dind" for s in services):
        volumes.append("certs-client:/certs/client:ro")

    compose["services"]["devcontainer"] = {
        "image": f"${{IMAGE_REPO:-ghcr.io/ebpro}}/${{IMAGE_NAME:-solen}}:${{IMAGE_TAG:-{image_tag}}}",
        "user": "jovyan",
        "environment": env,
        "volumes": volumes,
        "networks": ["notebooknet"],
        "depends_on": depends_on,
        "command": "sleep infinity"
    }

    # Ensure jupyter-work volume exists
    compose["volumes"]["jupyter-work"] = None

    return compose


def main():
    if len(sys.argv) < 2:
        print("Usage: generate-devcontainer-json.py <profile-name>")
        sys.exit(1)

    profile_name = sys.argv[1]
    repo_root = Path(__file__).parent.parent

    # Try generated profiles first, then fall back to profiles/
    profile_path = repo_root / "generated" / "profiles" / profile_name
    if not profile_path.exists():
        profile_path = repo_root / "profiles" / profile_name

    features_dir = repo_root / ".devcontainer" / "features"
    templates_dir = repo_root / "devcontainer" / "service-templates"
    output_dir = repo_root / "generated" / "devcontainer" / profile_name

    if not profile_path.exists():
        print(f"Error: Profile not found in generated/profiles/{profile_name} or profiles/{profile_name}")
        sys.exit(1)

    # Read profile features and services
    features, services = read_profile_features(profile_path)
    print(f"Profile '{profile_name}' uses {len(features)} features and {len(services)} services")

    # Collect VS Code metadata from features
    vscode_metadata = collect_vscode_metadata(features_dir, features)
    print(f"Collected {len(vscode_metadata['extensions'])} extensions")

    # Generate devcontainer.json
    has_services = len(services) > 0
    devcontainer = generate_devcontainer_json(
        profile_name,
        vscode_metadata,
        f"{profile_name}-develop",
        has_services
    )

    # Write devcontainer.json
    output_dir.mkdir(parents=True, exist_ok=True)
    devcontainer_path = output_dir / "devcontainer.json"
    with open(devcontainer_path, "w") as f:
        json.dump(devcontainer, f, indent=2)
    print(f"Generated: {devcontainer_path}")

    # Generate docker-compose.yml if services are defined
    if services:
        compose = generate_docker_compose(
            profile_name,
            services,
            f"{profile_name}-develop",
            templates_dir
        )

        compose_path = output_dir / "docker-compose.yml"
        with open(compose_path, "w") as f:
            yaml.dump(compose, f, default_flow_style=False, sort_keys=False)
        print(f"Generated: {compose_path}")


if __name__ == "__main__":
    main()
