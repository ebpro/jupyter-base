# solen — Agent Quick Reference

## What This Is
Modular devcontainer base-image factory. ~65 features, ~33 profiles generated from
8 YAML matrices, multi-arch (amd64/arm64) publishing to `ghcr.io/ebpro/solen`.
The GitHub repo is `ebpro/jupyter-base`; the image and the CLI are both named
`solen`.
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

## Feature: opencode
Installs the OpenCode AI coding agent (`opencode-ai`, global npm, version-pinned) and,
when `SSH_PRIVATE_KEY` is provided at build time, clones the private
`git@github.com:ebpro/opencode-config.git` repo into the dev user's
`~/.config/opencode/`. `dependsOn: node`. Reference: `features/opencode/`.

- **Build-time input:** `SSH_PRIVATE_KEY` (deploy key with read access to
  `ebpro/opencode-config`). Written to a temp file (mode `600`), used only for the
  clone, removed via an `EXIT` trap. Without it, only the binary is installed.
- **Runtime env vars (credential-agnostic, provided by the caller, never baked in):**
  - `VLLM_API_KEY` — API key for the vLLM-backed LLM endpoint.
  - `LIS_LAB_API_KEY` — API key for the LIS Lab LLM endpoint.
- **CI wiring:** `ci-publish.yml` passes `SSH_PRIVATE_KEY` to every build job as a
  `--build-arg`, so the private config is baked in whenever the repo/org secret is
  set. If the secret is unset, only the binary is installed (the clone is skipped).

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
- `ci-build.yml` — push to develop + PR + dispatch: single-arch build on the
  in-cluster ARC runner (`runs-on: ebpro-org`, docker:dind sidecar). Default
  profile: **`quarto-full`** (MVP). Produces SBOM (syft) + Trivy scan per profile.
- `ci-publish.yml` — push to develop / tag `v*` / dispatch: multi-arch publish to
  GHCR, **5 jobs**:
  1. `build-amd64-core` — `runs-on: ebpro-org`, standard (non-heavy) profiles,
     native amd64.
  2. `build-amd64` — `runs-on: ebpro-org-large`, heavy/flagship profiles
     (`quarto-full`, `lang-java-*`, `quarto-java-*`), native amd64.
  3. `build-arm64` — `runs-on: ebpro-org-arm`, all profiles, native arm64.
     `v*` / dispatch only (the develop fast path is amd64-only).
  4. `merge-index` — folds the per-arch images into an OCI index (manifest list)
     at the base tag via `docker buildx imagetools create`. `v*` / dispatch only.
  5. `sign-release` — signs the merged `solen` indexes with cosign. `v*` only.
  Each build job bakes with the buildx `docker-container` driver and a Harbor
  registry cache (`harbor.ebruno.fr/solen/build-cache:<profile>-<arch>`, robot
  `robot$arc-runner-ci`, pull+push). No QEMU/binfmt — each arch builds natively on
  its own runner pool.
- `validate-artefacts.yml` — `artefacts/**` changes: checksum validation.
- `cleanup-ghcr.yml` — schedule: GC old GHCR tags.
- **Per-arch tags:** on `v*` / dispatch every tag is suffixed per-arch
  (`<profile>-<tag>-amd64`, `<profile>-<tag>-arm64`) and `merge-index` folds them
  into a multi-arch index at `<profile>-<tag>`. On a develop push the build is
  amd64-only with unsuffixed tags.
- **Runners:** 3 ARC pools — `ebpro-org` (standard amd64), `ebpro-org-large`
  (heavy/flagship amd64), `ebpro-org-arm` (arm64).

## Gotchas
- `.venv/` at repo root is **untracked and not gitignored** — stage explicit paths,
  never `git add -A`.
- Feature bundles (`bundle-base-full`, `bundle-quarto-full`, ...) are meta-features;
  they appear in profiles, their `dependsOn` is the actual content.
- Prebaking: `scripts/utils/inject_prebaked_helpers.sh` rewrites install-script
  helper-source blocks so builds use `/opt/solen/_lib/helpers.sh`.
- `artefacts/` + root `checksums.json` (`tools.<name>.checksums.<version>.<arch>`)
  feed `fh_verify_from_checksums` in install scripts.
- Tag format: `ghcr.io/ebpro/solen:<profile>-<tag>`; on `v*`/dispatch each tag is
  also suffixed per-arch (`-amd64`/`-arm64`) and folded into a manifest list at the
  base tag by `merge-index`.

## No Package Manager for the Repo Shell
Repo tooling is Bash + the `solen-cli` Python package (`pip install -e solen-cli[dev]`
for the dev gate). No npm/cargo/go.
