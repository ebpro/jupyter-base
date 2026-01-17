# Solen CLI

Command-line tool for managing Solen container features, profiles, and generated artifacts.

## Installation

```bash
# Development installation
cd solen-cli
pip install -e .

# With dev dependencies
pip install -e ".[dev]"
```

## Usage

```bash
# Generate profiles from matrix
solen generate profiles --matrix profiles/matrix/dev.yaml

# Generate Dockerfile
solen generate dockerfile --profile quarto-lecture-full

# Generate devcontainer.json
solen generate devcontainer --profile minimal

# Generate docker-bake.hcl
solen generate bake

# Generate feature READMEs
solen generate readmes --output features/

# Validate feature structure
solen validate features

# Analyze features and generate matrix
solen analyze features --output generated/feature-matrix.md
```

## Commands

### `solen generate`
- `profiles` - Generate profile files from YAML matrix definitions
- `dockerfile` - Generate Dockerfile for a profile
- `devcontainer` - Generate devcontainer.json for a profile
- `bake` - Generate docker-bake.hcl for all profiles
- `readmes` - Generate README.md files for all features

### `solen validate`
- `features` - Validate all features against schema

### `solen analyze`
- `features` - Analyze features and generate dependency matrix

## Architecture

```
solen/
├── core/           # Core models and logic
│   ├── profile.py      # Profile loading and expansion
│   ├── feature.py      # Feature models and validation
│   └── dependency.py   # Dependency resolution
├── generators/     # File generators
│   ├── dockerfile_gen.py
│   ├── devcontainer.py
│   ├── bake.py
│   ├── profiles.py
│   └── readme.py
├── validators/     # Validation logic
│   └── features.py
└── utils/          # Utilities
    └── mermaid.py
```

## Migration from Bash Scripts

This tool replaces the following bash scripts:
- `scripts/generate-dockerfile.sh` → `solen generate dockerfile`
- `scripts/generate-devcontainer.sh` → `solen generate devcontainer`
- `scripts/generate-bake.sh` → `solen generate bake`
- `scripts/generate-profiles-matrix.py` → `solen generate profiles`
- `scripts/features/generate-feature-readmes.py` → `solen generate readmes`
- `scripts/validate/validate-feature-structure.py` → `solen validate features`
