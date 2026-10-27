# solen — Agent Quick Reference

## What This Is
Modular devcontainer base-image factory. ~65 features, ~31 profiles generated from
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
  `--build-arg`, but `opencode` is in no profile or bundle today, so its installer
  never runs in image builds: nothing is baked and the key plumbing is unused.
  The previously-referenced `ghcr.io/ebpro/solen/opencode:1.0.0` devcontainer feature
  image does not exist (`404 NAME_UNKNOWN` under an authenticated pull token, no
  publisher found in this repo or in Gitea); the references were removed from
  `devcontainer/template/devcontainer.json` and `features/opencode/README.md`.

## Build Commands
```bash
# Local venv (never `python -m solen` — use the entry point)
.venv/bin/solen <command>

# Full build (always regenerates profiles + Dockerfile + bake via --chain; --push → buildx bake --push, else --load; default profile quarto-full)
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
CI passes the bake generator `--harbor-cache harbor.ebruno.fr/solen/build-cache
--tag-suffix <arch> --no-build-tag --platforms linux/<arch>` (all triggers —
per-arch suffixes are unconditional, so every trigger publishes `-amd64`/`-arm64`
tags before `merge-index` folds them).

**Registry-cache flags for `solen generate bake` (only meaningful with
`--harbor-cache`, and NOT interchangeable):**
- `--no-cache-to` — omits `cache-to` (the export) and **deliberately keeps
  `cache-from`** (the import). Correct for Harbor's `499` on a large-layer
  upload, where reading the cache still works.
- `--no-cache` — omits **both** `cache-from` and `cache-to`. Correct when the
  cache registry is unreachable or unauthenticated. Using `--no-cache-to` for
  that case leaves a dead registry as the import source and is *not* a
  fallback: the bake keeps referencing the unavailable cache.
- Different flag, same words: `--no-cache` on `./build.sh` and on `solen build`
  sets buildx `*.no-cache=true`; it has nothing to do with bake cache
  directives.

## Validation (the local gate)
```bash
.venv/bin/solen validate features          # feature graph: deps, cycles, ordering
.venv/bin/solen versions sync --check      # versions.json matches versions.yaml
.venv/bin/python -m pytest tests/ solen-cli/tests -q   # full test suite (root tests/ + solen-cli/tests/)
ruff check solen-cli tests                 # lint
actionlint                                 # workflow lint (developer-provided; no args → lints .github/workflows/; config .github/actionlint.yaml)
```

## CI / Release
- `ci-validate.yml` — push to main/develop + PRs: full local gate.
- `ci-build.yml` — `workflow_run` (fires **after** "Publish to GHCR" completes on
  develop) + PR to develop + dispatch — **not** a plain develop push. In-cluster
  ARC runner (`runs-on: ebpro-org`, docker:dind sidecar). On the develop-promotion
  path it PULLS the image `ci-publish.yml` already pushed (`<profile>-<short-sha>`,
  native arch, amd64 fallback) instead of rebuilding; only PR/dispatch build.
  Default profile: **`quarto-full`** (MVP). Produces SBOM (syft) + Trivy scan per
  profile.
- `ci-publish.yml` — push to develop / tag `v*` / dispatch: multi-arch publish to
  GHCR, **7 jobs** (the three build jobs carry no per-trigger gate — all run on
  every trigger):
  1. `build-amd64-standard` — `runs-on: ebpro-org`, standard (non-heavy) profiles,
     native amd64.
  2. `build-amd64-heavy` — `runs-on: ebpro-org-large`, heavy/flagship profiles —
     `is_heavy()` = `quarto-full|lang-java-*|quarto-java-*` — native amd64.
  3. `build-arm64` — `runs-on: ebpro-org-arm`, all profiles, native arm64.
  4. `merge-index` — `needs` all three builds; folds the per-arch images into an
     OCI index (manifest list) at the base tag via `docker buildx imagetools
     create`. Every trigger (`if: ${{ !cancelled() }}`).
  5. `verify-published` — `needs: [merge-index]`, `if: ${{ !cancelled() }}`
     (every trigger), amd64 pool (`[self-hosted, linux, x64, ebpro-org]`). Re-runs the baked
     post-install contract plus an independent binary floor against the
     published `-amd64` tags. Leaf job: nothing needs it. See `docs/TESTING.md`.
  6. `verify-published-arm64` — `needs: [merge-index]`, `if: ${{ !cancelled() }}`,
     `runs-on: ebpro-org-arm`. Validates the **folded multiarch index**
     (the unsuffixed base tag, not the `-arm64` child) on real arm64 hardware:
     imagetools fold integrity, `docker image inspect` arch guard, the baked
     contract with `N/M passed` asserted, in-container `uname -m`, a real
     `quarto render`/JVM probe, and a hazard sweep. Cost-capped to a documented
     representative subset (`quarto-full lang-java-25 db-postgres minimal`)
     because the arm pool is `minRunners: 0` / `maxRunners: 2`. Leaf job. See
     `docs/TESTING.md`.
  7. `sign-release` — signs the merged `solen` indexes (and their per-arch
     children) with cosign **keyless** (Sigstore/Fulcio OIDC via the default
     `GITHUB_TOKEN`): no provisioned key, the job reads no secrets. Job-level
     `permissions` (which override the workflow block) grant `id-token: write`
     (OIDC mint) + `packages: write` (sig-manifest push). Sign is digest-pinned
     (`cosign sign --yes …@sha256:…`, never by tag); verify is a HARD gate
     (`cosign verify --certificate-oidc-issuer
     https://token.actions.githubusercontent.com --certificate-identity-regexp
     '^https://github.com/<owner>/<repo>/.github/workflows/ci-publish\.yml@refs/tags/v.*$'`),
     so a tag run fails unless every ref carries a verifiable signature from
     this workflow on a tag ref — the old key-based soft-skip "vacuous green"
     is gone. Guarded by `if: ${{ startsWith(github.ref, 'refs/tags/v') &&
     !cancelled() }}` — it skips by design on a `develop` push and on dispatch;
     the `!cancelled()` clause is the skipped-ancestor cascade guard (run
     40173553597 is the proof).
  Each build job bakes with the buildx `docker-container` driver and a Harbor
  registry cache (`harbor.ebruno.fr/solen/build-cache:<profile>-<arch>`, robot
  `robot$arc-runner-ci`, pull+push). **Harbor is a soft dependency, not a
  publish requirement:** an unauthenticated `GET /v2/` probe treats `200|401` as
  alive (`401` is the healthy registry challenge), the login step is
  `continue-on-error`, and `HARBOR_READY` selects `generated/docker-bake.hcl`
  vs a cache-less `generated/docker-bake-nocache.hcl`. A failed build then
  retries cache-to-less and finally fully cache-less. Cost of a Harbor outage is
  a cold build, never a failed publish. No QEMU/binfmt — each arch builds
  natively on its own runner pool. Dispatch with empty `profiles` = every
  generated profile.
- `validate-artefacts.yml` — `artefacts/**` changes: checksum validation.
- `cleanup-ghcr.yml` — schedule: GC old GHCR tags.
- **Per-arch tags:** on every trigger each tag is suffixed per-arch
  (`<profile>-<tag>-amd64`, `<profile>-<tag>-arm64`) and `merge-index` folds them
  into a multi-arch index at `<profile>-<tag>`.
- **Runners:** 3 ARC pools — `ebpro-org` (standard amd64), `ebpro-org-large`
  (heavy/flagship amd64), `ebpro-org-arm` (arm64).

## Gotchas
- `.venv/` at repo root is **untracked and gitignored** — stage explicit paths,
  never `git add -A`.
- Feature bundles (`bundle-base-full`, `bundle-quarto-full`, ...) are meta-features;
  they appear in profiles, their `dependsOn` is the actual content.
- Prebaking: `scripts/utils/inject_prebaked_helpers.sh` rewrites install-script
  helper-source blocks so builds use `/opt/solen/_lib/helpers.sh`.
- `artefacts/` + root `checksums.json` (`tools.<name>.checksums.<version>.<arch>`)
  feed `fh_verify_from_checksums` in install scripts.
- **apt presence checks on Ubuntu 24.04 (time_t64):** `libpng16-16` is a *virtual*
  provider there. `apt-get install libpng16-16` succeeds but installs
  `libpng16-16t64`, while `dpkg-query -W -f='${Status}' libpng16-16` answers
  `unknown ok not-installed` — so a check written against the bare name fails on a
  correctly installed image. Verify the `t64` name (`tests/test_apt_packages_required.py`).
  `libx11-6` is a real package name, not a `t64` alias — do not "fix" it.
- Tag format: `ghcr.io/ebpro/solen:<profile>-<tag>`; on every trigger each tag is
  suffixed per-arch (`-amd64`/`-arm64`) and folded into a manifest list at the
  base tag by `merge-index`.

## No Package Manager for the Repo Shell
Repo tooling is Bash + the `solen-cli` Python package (`pip install -e solen-cli[dev]`
for the dev gate). No npm/cargo/go.
