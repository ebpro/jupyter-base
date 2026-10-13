# `scripts/`

Shell and Python helpers that support building, testing, and preparing the solen
images. This directory holds **build/test helpers**, **shared shell libraries**
(feature-install and build functions), and a few **standalone utilities**
(artefact offload/fetch, checksums, prebake, and a Mermaid diagram generator).

Profile generation, Dockerfile/bake generation, feature validation, and version
sync are **not** here — they live in the `solen` CLI (see `solen-cli/`). See the
[Analysis tools now live in the CLI](#analysis-tools-now-live-in-the-cli) section
below.

> The repo-root `build.sh` is the top-level build entry point (`./build.sh [profile]`).
> `scripts/lib/build.sh` is a *different* file: a shared helper library sourced by
> build scripts. Do not confuse the two.

## Directory layout

```
scripts/
├── README.md                          # This file
├── arch.sh                            # Shim: exposes arch_map/arch_aliases (delegates to utils/arch.sh)
├── feature_helpers.sh                 # Shim: exposes feature helper functions to install scripts
├── fix_feature_helpers.py             # One-shot: rewrites install.sh helper-source paths
├── prebake-toolcache.sh               # Pre-download & cache common tools to /opt/toolcache
├── validate-artefacts.sh              # Verify integrity of the offloaded artefacts tree
├── lib/
│   ├── build.sh                       # Shared build helpers (buildx check, builder, platforms)
│   ├── features.sh                    # Feature-install helper functions (+ compat shim)
│   └── helpers.sh                     # Shared helper functions for feature install scripts
├── utils/
│   ├── arch.sh                        # arch_map / arch_aliases normalization
│   ├── fetch-artefacts.sh             # Download & extract offloaded artefacts into ./artefacts
│   ├── fetch-gitstatus-artifacts.sh   # Fetch gitstatusd tarballs, extract, update checksums
│   ├── fetch-java-kernel-artifacts.sh # Fetch IJava/java-kernel tarballs, extract, write checksums
│   ├── generate_mermaid.py            # Mermaid diagram: profiles → features (stdout / --out)
│   ├── inject_prebaked_helpers.sh     # Inject helper-source snippet into feature install.sh files
│   ├── offload-artefacts.sh           # Collect large artefacts, build tarball + manifest
│   └── update-checksums.sh            # Download pinned binaries, compute SHA256, update checksums.json
└── test/
    ├── test-all-features.sh           # Test many features with reporting (parallel option)
    ├── test-feature.sh                # Test a single feature in an isolated container
    └── test-profile.sh                # Smoke-test a built profile image
```

Generated artefact (not source, safe to delete):

- `utils/__pycache__/generate_mermaid.cpython-312.pyc` — Python bytecode cache produced
  when `generate_mermaid.py` is imported/run.

## File reference

### Top level

| Path | Purpose |
|------|---------|
| `arch.sh` | Lightweight shim that sources `utils/arch.sh` so `arch_map` / `arch_aliases` are available at the `scripts/arch.sh` path. |
| `feature_helpers.sh` | Shim so feature `install.sh` scripts can source feature helper functions; loads `lib/features.sh` (falling back to `/opt/solen/_lib/helpers.sh` inside images). |
| `fix_feature_helpers.py` | One-shot maintenance script: rewrites `../../../scripts/feature_helpers.sh` references in `features/**/install.sh` to `../../../scripts/lib/features.sh`. |
| `prebake-toolcache.sh` | Pre-downloads and caches a set of common tools (default: `gh,kubectl,helm,k9s,kustomize,quarto,tilt,gitstatus,miniforge,node`) to `/opt/toolcache` for faster builds. Configurable via `--tools`, `--archs`, `--output`, `--versions`. |
| `validate-artefacts.sh` | Verifies integrity of the offloaded artefacts tree: checks each `toolcache-manifest-*.json`, its referenced tarball, and the SHA256. Requires `jq`. |

### `lib/` — shared shell libraries

| Path | Purpose |
|------|---------|
| `build.sh` | Shared build helpers: `check_buildx`, `create_builder_if_missing`, `normalize_platforms`. Sourced by build scripts (not the repo-root `build.sh`). |
| `features.sh` | Feature-install helper functions (e.g. `fh_log`, `feature_marker`, `feature_is_installed`, `feature_mark_installed`), with a compatibility shim that also loads `helpers.sh` (or `/opt/solen/_lib/helpers.sh` in images). |
| `helpers.sh` | Shared helper functions for feature install scripts (e.g. `apt_install`, feature markers, logging). |

### `utils/`

| Path | Purpose |
|------|---------|
| `arch.sh` | Normalizes architecture names: `arch_map <input>` → canonical arch; `arch_aliases <canon>` → asset-name variants. |
| `fetch-artefacts.sh` | Downloads and extracts offloaded artefacts into `./artefacts`. Accepts a direct URL (`--url` / `ARTEFACT_URL`) or a manifest + base URL (`--manifest` + `ARTEFACTS_BASE_URL`); optional `--no-verify`. |
| `fetch-gitstatus-artifacts.sh` | Fetches `gitstatusd` release tarballs per arch, extracts into `artefacts/`, and updates the per-feature checksums. Version from `versions.json` (`.tools.gitstatus`) or an argument. |
| `fetch-java-kernel-artifacts.sh` | Fetches IJava / java-kernel release tarball(s), extracts into `artefacts/java-kernel/...`, and writes per-feature checksums. Version from `versions.json` (`.tools.java-kernel`) or an argument. |
| `generate_mermaid.py` | Generates a Mermaid `flowchart LR` of profiles → (bundle-expanded) leaf features → parent. Writes the diagram to the `--out` file (default `docs/diagrams/features-profiles.mmd`) and also echoes it to stdout (status on stderr). Prefers the canonical source `solen.generators.readme.collect_profile_features`; falls back to a naive text scan if the `solen` package is not importable. |
| `inject_prebaked_helpers.sh` | Scans `features/*/install.sh` and injects a helper-source snippet so builds use the prebaked `/opt/solen/_lib/helpers.sh` (falling back to the repo helper). |
| `offload-artefacts.sh` | Collects large artefacts (toolcaches) under `artefacts/`, builds a tarball + manifest, and prints the git commands to publish them. `--dry-run` (default) / `--no-dry-run`, `--dest`. |
| `update-checksums.sh` | Downloads binaries for pinned versions, computes SHA256, and updates the repo-root `checksums.json` (format `tools.<name>.checksums.<version>.<arch>`). |

### `test/`

| Path | Purpose |
|------|---------|
| `test-all-features.sh` | Orchestrates testing of multiple features with reporting; supports parallelism and report output. |
| `test-feature.sh` | Tests an individual feature in an isolated container (`FEATURE_ID [--build-first] [--verbose]`). |
| `test-profile.sh` | Smoke-tests a built profile image (`<image> [profile-name]`). |

## Analysis tools now live in the CLI

The analysis/diagnostic capabilities that older documentation attributed to a
`scripts/analysis/` (and `scripts/validate/`, `scripts/features/`) script tree are
**no longer shell scripts in this directory** — those trees are gone. That work now
lives in the `solen` CLI (`solen-cli/`), run via the local entry point
(`.venv/bin/solen <command>`):

| Command | What it does | Output |
|---------|--------------|--------|
| `solen analyze features` | Builds the feature × profile usage matrix (bundle expansion + `@parent` resolution). | Writes `generated/feature-matrix.md` (default). |
| `solen analyze layer-sharing` | Builds the `FROM`-layer sharing DAG: direct bases via poset covers, transitive ancestor chains, and per-edge shared/delta/ratio metrics, rendered as Mermaid. | Writes `generated/layer-sharing.md` (default). |

`scripts/utils/generate_mermaid.py` remains a **standalone** utility for the
profile → feature Mermaid diagram (it does not replace the two `solen analyze`
commands above).

## Requirements

- **bash 4+** (associative arrays in shell scripts).
- **jq** for `validate-artefacts.sh`, `update-checksums.sh`, and the fetch scripts.
- **Python 3** for `fix_feature_helpers.py` and `utils/generate_mermaid.py`.
- **docker buildx** for the build helpers in `lib/build.sh` when building.
