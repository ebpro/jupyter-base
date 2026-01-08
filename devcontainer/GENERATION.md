# Auto-generating devcontainer.json and docker-compose.yml from Profiles

## Overview

The `devcontainer.json` and `docker-compose.yml` files for each profile are **auto-generated** from:
- **Feature metadata:** VS Code extensions and settings
- **Profile services:** Sidecar services (dind, databases, etc.)

**Source of truth:**
- Feature `feature.json` files declare their recommended VS Code extensions and settings.
- Profile files declare required services using `@services:` directives.

## Feature Metadata

Add a `vscode` field to `feature.json`:

```json
{
  "id": "python-base",
  "name": "Python Base",
  "vscode": {
    "extensions": [
      "ms-python.python",
      "ms-python.vscode-pylance"
    ],
    "settings": {
      "python.defaultInterpreterPath": "/usr/bin/python3"
    },
    "forwardPorts": [8000]
  }
}
```

### Fields

- `extensions` (array of strings): VS Code extension IDs to install.
- `settings` (object): VS Code settings to apply (merged, later features override).
- `forwardPorts` (array of numbers): Ports to forward from container.

## Profile Service Declarations

Add `@services:` directives to profile files to declare required sidecars:

```
# profiles/quarto-lecture-containers

# Features
bundle-base-full
docker-dind
postgresql-client

# Options
@options:JDK_VERSION=25

# Services/Sidecars
@services:dind
@services:postgres:version=16
@services:mysql:version=8.0
@services:redis
```

### Service Syntax

```
@services:<name>[:<option>=<value>,<option2>=<value2>]
```

### Available Services

- `dind` — Docker-in-Docker with TLS
- `postgres[:version=16]` — PostgreSQL database
- `mysql[:version=8.0]` — MySQL database
- `mongo[:version=8.0]` — MongoDB
- `redis[:version=7]` — Redis
- `registry` — Local container registry

Service templates are in `devcontainer/service-templates/`.

## Generating devcontainer.json and docker-compose.yml

From the repository root:

```bash
python3 scripts/generate-devcontainer-json.py <profile-name>
```

Example:

```bash
python3 scripts/generate-devcontainer-json.py quarto-lecture-containers
```

This will:
1. Read `profiles/<profile-name>` to get the feature list and services.
2. Resolve feature dependencies recursively.
3. Collect `vscode` metadata from all features.
4. Load service templates and merge them.
5. Generate `generated/devcontainer/<profile-name>/devcontainer.json`.
6. Generate `generated/devcontainer/<profile-name>/docker-compose.yml` (if services declared).

Generated files are placed in `generated/devcontainer/` (gitignored) to separate them from hand-written templates.

## Workflow

### Adding a new feature

1. Add `vscode` metadata to `.devcontainer/features/<feature>/feature.json`.
2. Regenerate affected profiles:
   ```bash
   python3 scripts/generate-devcontainer-json.py <profile-name>
   ```

### Adding a new profile

1. Create `profiles/<new-profile>` with feature list and services.
2. Generate devcontainer files:
   ```bash
   python3 scripts/generate-devcontainer-json.py <new-profile>
   ```

### Adding a new service

1. Create `devcontainer/service-templates/<service>.yml` with service definition.
2. Add `@services:<service>` to profiles that need it.
3. Regenerate affected profiles.

### Updating extensions

- **Do not** manually edit `devcontainer.json`.
- Update feature `feature.json` files.
- Regenerate using the script.

## CI Integration (recommended)

Add a CI check to ensure generated files are up-to-date:

```bash
# Regenerate all profiles
for profile in profiles/*; do
  if [ -f "$profile" ]; then
    name=$(basename "$profile")
    python3 scripts/generate-devcontainer-json.py "$name"
  fi
done

# Check for uncommitted changes
git diff --exit-code devcontainer/
```

## Manual Overrides

If you need profile-specific customizations not derived from features:

1. Keep them in `docker-compose.yml` environment variables or compose overrides.
2. Or, fork the generation script and add custom logic for specific profiles.

Avoid manual edits to generated `devcontainer.json` — they will be overwritten.
