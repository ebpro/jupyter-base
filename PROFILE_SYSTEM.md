# Profile and Devcontainer System - Complete Guide

## Overview

This document describes the complete profile and devcontainer generation system implemented in the solen project.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Source Definitions                        │
├─────────────────────────────────────────────────────────────────┤
│  profiles/                    profiles/matrix/*.yaml             │
│  ├── base                     ├── java-dev.yaml (5 variants)    │
│  ├── full                     ├── quarto-lecture.yaml (4)       │
│  ├── web-dev                  ├── data-science.yaml (2)         │
│  └── ...                      └── k8s-dev.yaml (2)              │
│                                                                  │
│  .devcontainer/features/*/feature.json                          │
│  └── vscode: {extensions, settings, forwardPorts}               │
│                                                                  │
│  devcontainer/service-templates/*.yml                           │
│  └── dind, postgres, mysql, mongo, redis, registry, k3s, ...   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                      Generation Scripts                          │
├─────────────────────────────────────────────────────────────────┤
│  scripts/generate-all-matrix-profiles.sh                        │
│  └→ scripts/generate-profiles-matrix.py                         │
│      └→ generated/profiles/*  (18 profiles)                     │
│                                                                  │
│  scripts/generate-all-devcontainers.sh                          │
│  └→ scripts/generate-devcontainer-json.py                       │
│      └→ generated/devcontainer/*/                               │
│          ├── devcontainer.json                                  │
│          └── docker-compose.yml                                 │
│                                                                  │
│  scripts/generate-dockerfile.sh --all-profiles                  │
│  └→ Dockerfile.generated (multi-stage)                          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                       Generated Outputs                          │
├─────────────────────────────────────────────────────────────────┤
│  generated/profiles/          (18 from matrix + 12 hand-written)│
│  generated/devcontainer/      (~32 configs)                     │
│  Dockerfile.generated         (all profile stages)              │
└─────────────────────────────────────────────────────────────────┘
```

## Profile Types

### Hand-Written Profiles (`profiles/`)

**Purpose**: Unique, specialized configurations that don't fit matrix patterns.

**Examples**:
- `base` - Minimal foundation (shell, git, docker-cli)
- `full` - Kitchen sink (all features)
- `web-dev` - Node/TypeScript/React development
- `kotlin` - Kotlin development with compiler
- `java-graal` - GraalVM native compilation
- `codeserver`, `jetbrains-gateway` - Remote IDE variants

**Syntax**:
```
# Purpose: Description

feature-name
another-feature

@options:OPTION=value
@services:postgres:version=16
```

### Matrix-Generated Profiles (`profiles/matrix/*.yaml`)

**Purpose**: Generate multiple variants from a single definition, sharing common features but differing in options or additional features.

**Examples**:

**`java-dev.yaml`** - 5 JDK variants:
```yaml
features:
  - bundle-base-full
  - bundle-dev-base
  - bundle-java-build
  - java-jdk
matrix:
  java-8: { options: { JDK_VERSION: 8 } }
  java-21: { options: { JDK_VERSION: 21 } }
  java-25: { options: { JDK_VERSION: 25 } }
  java-ea: { options: { JDK_VERSION: ea } }
  java-latest: { options: { JDK_VERSION: latest } }
```

**`quarto-lecture.yaml`** - 4 teaching variants:
```yaml
features:
  - bundle-base-full
  - bundle-dev-base
  - bundle-data-science
options:
  INSTALL_NOTEBOOK_EXTENSIONS: true
matrix:
  quarto-lecture:
    features: [bundle-quarto-base]
  quarto-lecture-full:
    features: [bundle-quarto-full, bundle-java-build, java-jdk]
    options: { JDK_VERSION: 25 }
  quarto-lecture-db:
    features: [bundle-quarto-base, postgresql-client, bundle-python-db]
    services: [postgres:version=16]
  quarto-lecture-containers:
    features: [bundle-quarto-full, docker-dind, postgresql-client]
    options: { JDK_VERSION: 25, ENABLEBUILDKIT: true }
    services: [dind, postgres:version=16]
```

## Feature Metadata

Features declare VS Code extensions and settings in `.devcontainer/features/*/feature.json`:

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

## Service Templates

Reusable sidecar service definitions in `devcontainer/service-templates/*.yml`:

**Available Templates**:
- **dind.yml** - Docker-in-Docker with TLS
- **postgres.yml** - PostgreSQL (configurable version)
- **mysql.yml** - MySQL 8.0
- **mongo.yml** - MongoDB 8.0
- **redis.yml** - Redis 7
- **registry.yml** - Container registry
- **k3s.yml** - Lightweight Kubernetes cluster
- **buildkit.yml** - BuildKit daemon

**Usage in Profiles**:
```
@services:postgres:version=16
@services:dind
@services:mysql:version=8.0
```

## Generation Workflows

### Full Regeneration

```bash
# 1. Generate matrix profiles from YAML
./scripts/generate-all-matrix-profiles.sh
# → generates 18 profiles in generated/profiles/

# 2. Generate devcontainer configs for all profiles
./scripts/generate-all-devcontainers.sh
# → generates ~32 devcontainer.json + docker-compose.yml

# 3. Generate multi-stage Dockerfile
./scripts/generate-dockerfile.sh --all-profiles --out Dockerfile.generated
# → generates Dockerfile with all profile stages
```

### Single Profile Generation

```bash
# Generate devcontainer for one profile
python3 scripts/generate-devcontainer-json.py quarto-lecture-containers

# Output:
# generated/devcontainer/quarto-lecture-containers/
#   ├── devcontainer.json    (18 extensions, customizations)
#   └── docker-compose.yml   (dind + postgres services)
```

### Build Integration

The `build.sh` script automatically runs generation:

```bash
# Generate and build
./build.sh --profile quarto-lecture-containers

# Just generate (no build)
./build.sh --generate-only

# Generate and build all profiles
./build.sh --all-profiles
```

## CI/CD Integration

### Validation Script

`scripts/validate-generated-files.sh` ensures generated files are up-to-date:

```bash
./scripts/validate-generated-files.sh

# Steps:
# 1. Regenerate matrix profiles
# 2. Regenerate devcontainers
# 3. Regenerate Dockerfile
# 4. Check git diff in generated/
# 5. Validate feature dependencies
# 6. Exit non-zero if stale
```

### GitHub Actions Workflow

`.github/workflows/validate-generated.yml` runs on:
- PRs touching profiles, features, or generation scripts
- Pushes to main/develop

**Checks**:
- Generated files match source definitions
- No manual edits to generated files
- Feature dependency graph is valid

## Key Benefits

### 1. Single Source of Truth

- Features declare extensions → devcontainer.json inherits them
- No manual sync between feature metadata and VS Code config
- Matrix YAML defines variants → profiles auto-generated

### 2. Consistency

- All db profiles use standardized service templates
- Options propagate correctly through matrix expansion
- Services start automatically with health checks

### 3. Scalability

- Adding a JDK version: edit `java-dev.yaml` matrix
- Adding a database: create `@services:` directive
- Adding an extension: edit feature's `vscode.extensions`

### 4. Maintainability

- CI fails if generated files are stale
- Clear separation: source vs generated
- Documentation co-located with generation logic

## File Locations

```
solen/
├── .devcontainer/features/        # Feature definitions (29 with vscode metadata)
├── profiles/                       # Hand-written profiles (12)
├── profiles/matrix/               # Matrix YAML definitions (8 files, 18 variants)
├── devcontainer/
│   ├── service-templates/         # 8 reusable service definitions
│   ├── README.md                  # Compose usage patterns
│   └── GENERATION.md              # Generation workflow docs
├── generated/                     # Auto-generated (gitignored)
│   ├── profiles/                  # 18 matrix-generated profiles
│   └── devcontainer/              # ~32 devcontainer configs
├── scripts/
│   ├── generate-all-matrix-profiles.sh
│   ├── generate-all-devcontainers.sh
│   ├── generate-profiles-matrix.py
│   ├── generate-devcontainer-json.py
│   ├── generate-dockerfile.sh
│   └── validate-generated-files.sh
├── .github/workflows/
│   └── validate-generated.yml     # CI validation workflow
└── build.sh                       # Build orchestrator with auto-generation
```

## Quick Reference

### Create New Hand-Written Profile

```bash
cat > profiles/my-profile <<'EOF'
# Purpose: My custom environment

bundle-base-full
bundle-dev-base
python-base

@options:PYTHON_VERSION=3.12
@services:postgres:version=16
EOF

python3 scripts/generate-devcontainer-json.py my-profile
```

### Create New Matrix Profile

```bash
cat > profiles/matrix/my-variants.yaml <<'EOF'
features:
  - bundle-base-full
  - bundle-dev-base
matrix:
  my-basic:
    options: {}
  my-db:
    features: [postgresql-client]
    services: [postgres:version=16]
EOF

./scripts/generate-all-matrix-profiles.sh
./scripts/generate-all-devcontainers.sh
```

### Add Service to Existing Profile

```bash
# Edit profile file
echo "@services:redis:version=7" >> profiles/python-db

# Regenerate
python3 scripts/generate-devcontainer-json.py python-db

# Test
docker compose -f generated/devcontainer/python-db/docker-compose.yml up -d
```

### Add Extension to Feature

```bash
# Edit feature metadata
cat >> .devcontainer/features/python-base/feature.json <<'JSON'
{
  "vscode": {
    "extensions": ["ms-python.python", "ms-python.vscode-pylance", "ms-python.black-formatter"]
  }
}
JSON

# Regenerate all devcontainers using this feature
./scripts/generate-all-devcontainers.sh
```

## Troubleshooting

### Generated files out of sync

```bash
./scripts/validate-generated-files.sh
# Follow the suggested fix commands
```

### Devcontainer not finding services

Check `docker-compose.yml` includes the service and `devcontainer.json` has correct `dockerComposeFile` path:

```json
{
  "dockerComposeFile": ["../../../generated/devcontainer/profile/docker-compose.yml"]
}
```

### Extensions not appearing in VS Code

1. Check feature has `vscode.extensions` in `feature.json`
2. Regenerate: `python3 scripts/generate-devcontainer-json.py <profile>`
3. Reload VS Code devcontainer

## Related Documentation

- [profiles/README.md](profiles/README.md) - Profile syntax and usage
- [devcontainer/README.md](devcontainer/README.md) - Compose patterns and service templates
- [devcontainer/GENERATION.md](devcontainer/GENERATION.md) - Auto-generation workflow
- [.github/workflows/validate-generated.yml](.github/workflows/validate-generated.yml) - CI validation
