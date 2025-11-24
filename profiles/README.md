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
