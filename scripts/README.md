# Scripts Directory

This directory contains all build, validation, and utility scripts for the solen project.

## Directory Structure

```
scripts/
├── README.md                          # This file
│
├── Core Build Scripts (in root)
├── generate-dockerfile.sh             # Generate multi-stage Dockerfile from profile
├── generate-bake.sh                   # Generate docker buildx bake configuration
├── generate-profiles-matrix.py        # Expand YAML matrices to profile files
├── generate-all-matrix-profiles.sh    # Batch generate all profiles from YAML
├── generate-all-devcontainers.sh      # Batch generate devcontainer.json files
├── generate-devcontainer.sh           # Generate single devcontainer.json
├── generate-devcontainer-json.py      # Python devcontainer.json generator
├── prebake-toolcache.sh               # Pre-download tools for offline builds
│
├── validate/                          # Validation & checking
│   ├── validate-feature-deps.py       # Check feature dependency graph
│   ├── validate-feature-deps.sh       # Shell wrapper for feature deps
│   ├── validate-generated-files.sh    # Verify generated files are current
│   ├── validate-system-consistency.py # Check overall system consistency
│   └── run-postinstall-checks.py      # Post-install validation
│
├── test/                              # Testing
│   ├── test-all-features.sh           # Test all feature installers
│   ├── test-feature.sh                # Test single feature installer
│   └── test-profile.sh                # Test profile build
│
├── features/                          # Feature management
│   ├── expand-feature-deps.py         # Recursively expand bundle dependencies
│   └── sort-features-by-deps.py       # Topological sort by dependencies
│
├── utils/                             # Utilities & helpers
│   ├── fetch-artefacts.sh             # Download pre-built artefacts
│   ├── fetch-gitstatus-artifacts.sh   # Download gitstatus binaries
│   ├── fetch-java-kernel-artifacts.sh # Download java-kernel artifacts
│   ├── offload-artefacts.sh           # Upload artefacts to storage
│   ├── update-checksums.sh            # Update artefact checksums
│   ├── generate-checksums.sh          # Generate checksum files
│   ├── inject_prebaked_helpers.sh     # Inject helper scripts into image
│   ├── arch.sh                        # Detect system architecture
│   └── generate_mermaid.py            # Generate dependency diagrams
│
├── analysis/                          # Analysis & development tools
│   ├── analyze-build-patterns.py      # Analyze build patterns
│   └── analyze-profile-features.py    # Analyze feature usage across profiles
│
└── lib/                               # Shared libraries
    ├── helpers.sh                     # Common shell functions
    ├── build.sh                       # Build workflow functions
    └── features.sh                    # Feature-specific helpers
```

## Main Workflows

### Build Workflow

1. **Profile Generation**: `generate-all-matrix-profiles.sh`
   - Reads YAML matrices from `profiles/matrix/*.yaml`
   - Generates text profiles in `generated/profiles/`
   - Expands feature dependencies

2. **Dockerfile Generation**: `generate-dockerfile.sh --profile <name>`
   - Reads profile from `generated/profiles/`
   - Generates `generated/Dockerfile` with all features

3. **Build**: `../build.sh --profile <name>`
   - Generates Dockerfile if needed
   - Builds multi-arch image with buildx
   - Generates bake configuration

### Validation Workflow

```bash
# Validate feature dependencies
./validate/validate-feature-deps.py

# Validate generated files are up-to-date
./validate/validate-generated-files.sh

# Run system-wide consistency checks
./validate/validate-system-consistency.py
```

### Testing Workflow

```bash
# Test single feature
./test/test-feature.sh <feature-name>

# Test all features
./test/test-all-features.sh

# Test profile build
./test/test-profile.sh <profile-name>
```

## CI/CD Usage

### GitHub Actions Workflows

- **ci-fetch-and-build.yml**: Uses `utils/fetch-artefacts.sh`, `generate-dockerfile.sh`, `generate-bake.sh`
- **validate-generated.yml**: Uses `generate-all-matrix-profiles.sh`, `validate/validate-feature-deps.py`
- **publish-ghcr.yml**: Uses `generate-dockerfile.sh`, `generate-bake.sh`

### Local Development

Core scripts used for local development:

```bash
# Generate all profiles
./generate-all-matrix-profiles.sh

# Generate and build specific profile
./generate-dockerfile.sh --profile quarto-lecture-full
../build.sh --profile quarto-lecture-full --load

# Validate before committing
./validate/validate-feature-deps.py
./validate/validate-generated-files.sh
```

## Script Categories

### Core Build Scripts (8 scripts)
Essential scripts for building images. These remain in the scripts root for easy access.

### Validation (5 scripts)
Scripts that check consistency, dependencies, and validate generated content.

### Testing (3 scripts)
Scripts for testing features and profiles.

### Features (2 scripts)
Scripts for managing feature dependencies and ordering.

### Utilities (9 scripts)
Helper scripts for fetching artefacts, generating checksums, etc.

### Analysis (2 scripts)
Development tools for analyzing build patterns and feature usage.

### Library (3 scripts)
Shared shell functions used by other scripts.

## Adding New Scripts

When adding new scripts:

1. Choose appropriate subdirectory based on purpose
2. Follow naming convention: `verb-noun.{sh|py}`
3. Add shebang and usage documentation
4. Update this README if it's a core workflow script
5. Update CI workflows if used in automation

## Script Dependencies

- **Python 3.8+**: Required for `.py` scripts
- **bash 4+**: Required for associative arrays in shell scripts
- **jq**: JSON parsing in shell scripts
- **yq**: YAML parsing (optional, Python fallback available)
- **docker buildx**: For multi-arch builds
