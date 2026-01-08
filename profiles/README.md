## Profile Syntax

```
# Purpose: Description

# Features (one per line)
bundle-base-full
bundle-dev-base
your-feature

# Options
@options:OPTION=value
@options:ANOTHER=value2

# Services (sidecar containers)
@services:postgres:version=16
@services:dind
```

### Directives

- **Features** - Plain text, one per line (e.g., `python-base`, `java-jdk`)
- **@options:** - Build/runtime options (e.g., `JDK_VERSION=25`)
- **@services:** - Sidecar services (e.g., `postgres:version=16`, `dind`, `mysql:version=8.0`)

## Workflows

### Create Hand-Written Profile

1. Create `profiles/<name>`:
   ```bash
   cat > profiles/my-profile <<'EOF'
   # Purpose: My custom profile

   bundle-base-full
   bundle-dev-base
   python-base

   @options:PYTHON_VERSION=3.12
   @services:postgres:version=16
   EOF
   ```

2. Generate devcontainer:
   ```bash
   python3 scripts/generate-devcontainer-json.py my-profile
   ```

3. Test:
   ```bash
   docker compose -f generated/devcontainer/my-profile/docker-compose.yml up -d
   ```

### Create Matrix Profile

1. Create `profiles/matrix/my-variants.yaml`:
   ```yaml
   # Purpose: Generate my-profile variants
   features:
     - bundle-base-full
     - bundle-dev-base
   options:
     COMMON_OPTION: value
   matrix:
     my-profile-basic:
       options: {}
     my-profile-db:
       features:
         - postgresql-client
       services:
         - postgres:version=16
   ```

2. Generate:
   ```bash
   ./scripts/generate-all-matrix-profiles.sh
   ./scripts/generate-all-devcontainers.sh
   ```

### Bulk Regeneration

After modifying features or matrix files:

```bash
# Regenerate matrix profiles
./scripts/generate-all-matrix-profiles.sh

# Regenerate all devcontainers
./scripts/generate-all-devcontainers.sh
```

## Legacy Documentation

The sections below describe the old profile system and are kept for reference.

Profile directory convention
----------------------------
Each profile is a directory under `profiles/` and may be prefixed with a numeric ordering token. Example:

  - `20-00-data-science/`

The numeric prefix is used only for ordering in lists; the generated tag slug drops the numeric prefix so image tags are human-friendly (e.g., `data-science`).

Profile contents
----------------
- `profile.json` (recommended) — optional metadata describing `slug`, `description`, `features` used, and any special build flags.
- `Dockerfile` or `Dockerfile.template` — profile-specific additions if needed (most logic lives in `features/`).

How to add a profile
---------------------
1. Create a directory under `profiles/` with a numeric prefix for ordering (optional).
2. Add a `profile.json` with at least `slug` and `features` listing.
3. Ensure features referenced exist under `features/`.
4. Run `./scripts/generate-dockerfile.sh --profile <profile-dir>` and validate the generated `Dockerfile.generated`.

Validation and CI
-----------------
CI should run a validator step that checks:
- `profile.json` is present and well-formed
- All listed features exist
- `slug` matches the expected pattern (lowercase letters, numbers, hyphens)

Tagging
-------
Tags produced by `build.sh` include profile slug prefixes and additional provenance (branch, short-sha, build date). Use `build-artifact.json` for the canonical list of tags and digest after building.

Examples
--------
`profiles/20-00-data-science/profile.json`:

```
{
  "slug": "data-science",
  "description": "Data science profile with conda, pandas, jupyterlab",
  "features": ["conda", "r-base", "quarto"]
}
```
# Profiles

This directory contains build/runtime profiles that compose features from `.devcontainer/features/`.

Each profile is a plain text file listing features (one per line). Lines starting with `#` are comments.

## Profile Types

### Hand-Written Profiles (`profiles/`)

Manually maintained profiles for specialized use cases:
- `base` - minimal foundation (shell, git, docker-cli)
- `full` - kitchen sink (all features, heavy)
- `codeserver`, `jetbrains-gateway` - remote IDE variants
- `web-dev`, `kotlin`, `java-graal` - specialized dev environments
- `db-multi`, `java-db-jdk25`, `ml-teaching` - domain-specific

Edit these directly when creating unique configurations.

### Matrix-Generated Profiles (`profiles/matrix/*.yaml`)

YAML files that generate multiple variants with different options:
- `java-dev.yaml` → 5 variants (java-8, 21, 25, ea, latest)
- `quarto-lecture.yaml` → 4 variants (base, full, db, containers)
- `data-science.yaml` → 2 variants (data-science, python-db)
- `k8s-dev.yaml` → 2 variants (k8s-dev, k8s-sim)

Generated profiles output to `generated/profiles/`.

## Profile Syntax
