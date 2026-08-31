# solen (jupyter-base) — Agent Quick Reference

## What This Is
Modular devcontainer base-image factory. ~70 features, ~33 profiles generated from
8 YAML matrices, multi-arch builds (amd64/arm64) publishing to `ghcr.io/ebpro/solen`.
**First MVP: `quarto-full`** — the lecture environment (java/zsh/bash kernels, zsh
shell, Chromium for headless rendering) that must build and run end-to-end before
any other profile.

## Critical Rules
- **NEVER edit anything in `generated/`** — profiles, Dockerfile, devcontainers and
  the bake file are regenerated from `features/` + `profiles/matrix/` on every build.
  Only `generated/profiles/.gitkeep` is tracked.
- **`features/` is the source of truth for features** — one directory per feature
  with `feature.json` + `install.sh`. Declare all dependencies in `dependsOn`.
- **Profiles are matrix-only** — no hand-written profile files. Edit
  `profiles/matrix/*.yaml`; profiles are generated with prefixed names
  (`lang-java-25`, `db-mysql`, `quarto-full`, ...).
- **Versions: `versions/versions.yaml` is the SoT.** `solen versions sync` regenerates
  the root `versions.json` (tracked; CI runs `solen versions sync --check`).
  Install scripts resolve versions via `fh_resolve_version` (see
  `features/_lib/fh_helpers.sh`), never hardcoded.
- **All Bash 4+.** Feature install scripts source helpers via
  `scripts/feature_helpers.sh` (or the prebaked `/opt/solen/_lib/helpers.sh` in images).

## Key Directories
| Path | Purpose |
|------|---------|
| `features/` | ~70 features (`feature.json` + `install.sh`), incl. `bundle-*` meta-features |
| `features/_lib/` | Shared install helpers (`fh_helpers.sh`, toolcache, download-release) |
| `profiles/matrix/*.yaml` | 8 matrices → all generated profiles |
| `scripts/` | Build helpers, lib (`lib/features.sh`, `lib/helpers.sh`), utils |
| `solen-cli/` | Python CLI (`solen`) — generators, validator, versions sync |
| `versions/` | `versions.yaml` (SoT) + tool definitions |
| `artefacts/` | Static per-feature data (java-kernel, quarto, ...); CI validates via checksums |
| `generated/` | Build-time output: profiles, Dockerfile, docker-bake.hcl, devcontainers (untracked) |
| `inputs/` | Shared build inputs (apt lists, conda, python, static files) |

## Build Commands
```bash
# Local venv (never `python -m solen` — use the entry point)
.venv/bin/solen <command>

# Full build (generates profiles + Dockerfile + bake, then builds; default profile quarto-full)
./build.sh [profile] [--load] [--push] [--no-cache] [--multi-arch]

# Generation only
.venv/bin/solen generate profiles --matrix profiles/matrix --out generated/profiles --chain
.venv/bin/solen generate dockerfile --all --output generated/Dockerfile
.venv/bin/solen generate bake --output generated/docker-bake.hcl

# Inspect
.venv/bin/solen list profiles
.venv/bin/solen inspect-profile <name>
.venv/bin/solen analyze features
```
Bake targets are `final-<profile>`; tags are `<registry>/<repo>:<profile>-<tag>`.

## Validation (the local gate)
```bash
.venv/bin/solen validate features          # feature graph: deps, cycles, ordering
.venv/bin/solen versions sync --check      # versions.json matches versions.yaml
pytest tests/ -q                           # solen-cli test suite
ruff check solen-cli tests                 # lint
/tmp/opencode/actionlint                   # workflow lint (config .github/actionlint.yaml)
```

## CI / Release
- `ci-validate.yml` — push to main/develop + PRs: full local gate.
- `ci-build.yml` — push to develop + dispatch: builds on the in-cluster ARC runner
  (`runs-on: ebpro-org`, docker:dind sidecar). Default profile: **`quarto-full`**
  (MVP). Produces SBOM (syft) + Trivy scan per profile.
- `ci-publish.yml` — tags `v*` / push main / dispatch: multi-arch publish
  (`tonistiigi/binfmt` + buildx `docker-container` driver) to ghcr.
- `release.yml` — tags `v*`: GitHub release notes from conventional commits.
- `validate-artefacts.yml` — `artefacts/**` changes: checksum validation.
- Runner: ARC ephemeral runners, namespace `arc-runners`, label `ebpro-org`,
  single amd64 node; multi-arch needs binfmt (QEMU) installed in the job.

## Gotchas
- `.venv/` at repo root is **untracked and not gitignored** — stage explicit paths,
  never `git add -A`.
- Feature bundles (`bundle-base-full`, `bundle-quarto-full`, ...) are meta-features;
  they appear in profiles, their `dependsOn` is the actual content.
- Prebaking: `scripts/utils/inject_prebaked_helpers.sh` rewrites install-script
  helper-source blocks so builds use `/opt/solen/_lib/helpers.sh`.
- `artefacts/` + root `checksums.json` (`tools.<name>.checksums.<version>.<arch>`)
  feed `fh_verify_from_checksums` in install scripts.
- Tag format: `ghcr.io/ebpro/solen:<profile>-<tag>`.

## No Package Manager for the Repo Shell
Repo tooling is Bash + the `solen-cli` Python package (`pip install -e solen-cli[dev]`
for the dev gate). No npm/cargo/go.
