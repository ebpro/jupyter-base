# solen (jupyter-base) — Agent Quick Reference

## What This Is
Modular devcontainer base image. ~60 features, ~26 profiles (hand-written + matrix-generated), multi-arch builds (amd64/arm64) publishing to `ghcr.io/ebpro/solen`.

## Critical Rules
- **NEVER edit `Dockerfile.generated` by hand** — it's regenerated every build via `scripts/generate-dockerfile.sh`. Tracked in git for review only.
- **Never merge `shared/_lib/helpers.sh` and `scripts/feature_helpers.sh`** — two copies by design: image-side vs. build-time. Keep in sync when adding functions.
- **All scripts require Bash 4+** — `generate-dockerfile.sh` uses associative arrays.

## Key Directories
| Path | Purpose |
|------|---------|
| `.devcontainer/features/` | ~60 features (each has `feature.json` + `install.sh`) |
| `profiles/` | Hand-written profile files (plain text, one feature per line) |
| `profiles/matrix/*.yaml` | 8 YAML files generating 10 variants each |
| `scripts/` | Generators, validators, build helpers |
| `shared/_lib/` | Image-baked helper lib (copied to `/opt/solen/_lib/` in containers) |
| `Artefacts/` | Prebaked toolcache, checksums |
| `generated/` | Matrix output, devcontainers (gitignored) |

## Build Commands
```bash
# Full build (auto-generates matrix profiles, Dockerfile, devcontainers, then builds)
./build.sh --profile <name> --load        # single profile, local load
./build.sh --profile <name> --push         # push to registry
./build.sh --all-profiles --push            # build + push all profiles
./build.sh --generate-only                  # regeneration only, no build

# Fastest iteration for single profile test
docker buildx build -f Dockerfile.generated --target final-<slug> --load -t solen:test .

# Regenerate all artifacts manually
./scripts/generate-all-matrix-profiles.sh
./scripts/generate-dockerfile.sh --all-profiles --out Dockerfile.generated
./scripts/generate-bake.sh
./scripts/generate-all-devcontainers.sh

# Preview without building
./build.sh preview
./build.sh validate
```

## Feature Helper Architecture
- **Image-side**: `shared/_lib/helpers.sh` → baked into images at `/opt/solen/_lib/helpers.sh`
- **Build-time**: `scripts/feature_helpers.sh` → used during local dev/builds
- Feature `install.sh` scripts source via dual fallback: `${FEATURE_HELPERS_DIR}/helpers.sh` first, then `../../../scripts/feature_helpers.sh`
- **Don't merge them** — they serve different stages. Keep function signatures in sync.

## Profile Syntax
```
# Features (one per line)
bundle-base-full
python-base

# Options and services
@options:PYTHON_VERSION=3.12
@services:postgres:version=16
```
- Hand-written: `profiles/<name>` (plain text file)
- Matrix: `profiles/matrix/*.yaml` → output to `generated/profiles/<name>`
- Numeric prefixes order profiles but are stripped from tags: `20-00-data-science` → tag `data-science`
- `generate-dockerfile.sh` reads from both `profiles/` AND `generated/profiles/`

## Important Gotchas
- `Dockerfile.generated` is in git AND in `.dockerignore` — the generator uses `-f` flag to read it; `.dockerignore` prevents stale copies in build context
- Feature bundles (e.g., `bundle-base-full`) are meta-features that list other features
- Prebake (`./build.sh --prebake`) populates `Artefacts/toolcache/` for faster builds but is opt-in
- Tag format: `<registry>/<repo>:<profile-slug>-<tag>` (profile slug strips numeric prefixes)
- `build.sh` produces `build-artifact.json` and `image-digest.txt` after each build

## Validation
```bash
bash scripts/validate-profiles.sh
python3 scripts/validate_features.py
bash scripts/validate-feature-deps.sh
```

## No Package Manager
Pure bash script project. No npm, cargo, go, pip requirements to install. Node imports target installed packages inside containers.
