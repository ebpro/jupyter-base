# Solen CLI

Command-line tool for managing Solen container features, profiles, versions, and
generated build artifacts. It replaces the former bash/python generator scripts and is
the only tooling used by the CI workflows.

## Installation

```bash
# From the repo root (editable)
pip install -e solen-cli

# With dev dependencies (pytest, ruff, ...)
pip install -e "solen-cli[dev]"
```

Requires Python ≥ 3.10.

## Commands

### `solen generate`
- `profiles` — expand `profiles/matrix/*.yaml` into `generated/profiles/`
  (`--matrix <dir> --out <dir> --chain` for hierarchical inheritance)
- `dockerfile` — generate the multi-stage `generated/Dockerfile`
  (`--profile <name>` or `--all`)
- `devcontainer` — per-profile `devcontainer.json` (+ `docker-compose.yml` when the
  profile defines services) (`--profile <name>` or `--all`)
- `bake` — generate `generated/docker-bake.hcl` for all profiles with
  git-aware tags

### `solen build`
End-to-end: generate Dockerfile + bake, then `docker buildx bake final-<profile>` while
injecting version build args from `versions.json`.
Options: `--profile <name>` (or `--target final-<name>`), `--platforms`, `--no-cache`.

### `solen versions`
- `sync` — flatten the source of truth (`versions/versions.yaml`) into the build-time
  manifest `versions.json` (`--source`, `--target`, `--check` for CI drift detection)
- `check` — compare pinned versions against upstream sources

### `solen validate`
- `features` — validate every feature against the schema (prints per-feature errors on
  failure; `--fix` auto-fixes common issues, `--verbose` adds warnings)
- `propagate-versions` — sync `versions.yaml` values into feature `options.version.default`
  (`--write` to apply, `--verbose` for the full report)

### `solen analyze`
- `features` — dependency matrix across features (`--output generated/feature-matrix.md`)

### `solen list` / `solen inspect-profile`
- `list profiles` — list generated profile files
- `inspect-profile <name>` — show resolved features/options/services of a profile

## Typical workflow

```bash
solen generate profiles --matrix profiles/matrix --out generated/profiles --chain
solen generate dockerfile --all --output generated/Dockerfile
solen generate bake --output generated/docker-bake.hcl
solen versions sync --check
solen validate features
```

## Layout

```
solen/
├── cli.py            # click command tree
├── core/             # models: profile, feature, dependency, versions
├── generators/       # profiles, dockerfile, devcontainer, bake (+ Jinja templates)
├── validators/       # feature schema/structure validation
└── utils/            # shared helpers
```

## Tests & lint

```bash
python -m pytest tests/     # from the repo root (tests/ is repo-level)
ruff check solen-cli
```
