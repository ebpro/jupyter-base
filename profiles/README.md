Profile naming and usage
========================

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

Each profile is a plain text file listing features (one per line). Lines starting with `#` are comments. A profile can include another profile using `@profile:<name>`.

Examples:
- `minimal` — smallest useful development image
- `dev` — developer workstation
- `data-science` — developer + Quarto + Jupyter
- `quarto-lecture` — lecture-focused image for Quarto dynamic execution
- `codeserver` — image variant for embedded Code‑Server UI

Usage:

1. Generate a Dockerfile for a profile:

```bash
./scripts/generate-dockerfile.sh --profile quarto-lecture --out Dockerfile.generated
```

2. Generate a `devcontainer.json` for a profile (for Codespaces/VS Code):

```bash
./scripts/generate-devcontainer.sh --profile quarto-lecture --out .devcontainer/devcontainer.generated.json
```

The generator scripts validate that each feature exists under `.devcontainer/features/`.
