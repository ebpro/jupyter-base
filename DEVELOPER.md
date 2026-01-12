DEVELOPER GUIDE
================

Purpose
-------
This repository builds and composes several Jupyter-based Docker images using a profile/feature model. It contains tooling to generate Dockerfiles, produce a `docker-bake.generated.hcl`, run multi-arch builds via `docker buildx`, and manage artefacts used by the images.

Quick prerequisites
-------------------
- `bash >= 4` (scripts assume associative arrays and other bash-4+ features)
- `docker` (20.10+ recommended) with `buildx` enabled
- `docker buildx` (use `docker buildx create --use` to create a builder)
- `gh` (GitHub CLI) for registry operations and cleanup workflow
- `jq` for JSON parsing in scripts
- `make` and `git` are helpful but optional for many workflows

Where things live
-----------------
- `profiles/matrix/` - profile definitions (YAML matrices)
- `generated/profiles/` - expanded profile feature lists
- `features/` - reusable feature installers used to assemble images
- `scripts/` - generators and helpers used by `build.sh`
- `scripts/lib/` - shared helper libraries (helpers.sh, build.sh, features.sh)
- `inputs/` - build inputs (apt packages, conda, python, static files)
- `artefacts/` - feature-specific static data (java-kernel, quarto, etc.)
- `generated/` - all generated content (Dockerfile, docker-bake.hcl, toolcache, etc.)
- `.github/workflows/` - CI, release, and cleanup workflows

Common tasks
------------
- Generate Dockerfile for a profile:
  - `./scripts/generate-dockerfile.sh --profile 20-00-data-science`
- Generate bake HCL for all profiles:
  - `./scripts/generate-bake.sh`
- Build a single profile and import locally (`--load`):
  - `./build.sh --profile 20-00-data-science --load`
- Build and push multi-arch images (CI or with registry credentials):
  - `./build.sh --all --push`

Prebake toolcache (optional)
------------------------------
- You can pre-download common large tools into `generated/toolcache` to speed local builds and avoid network downloads during image builds.
- To run prebake as part of the build, use the new flags on `build.sh`:
  - `./build.sh --prebake --profile quarto-lecture-full` will run `./scripts/prebake-toolcache.sh --output generated/toolcache` before generating Dockerfiles.
  - Use `--force-prebake` to re-run prebake even if `generated/toolcache` already exists.
  - Use `--ignore-prebake-errors` to continue the build even when prebake fails.

Note: prebake is opt-in to avoid surprising CI runs; it is recommended for local development when you want repeatable, fast builds.

Tagging and artifacts
---------------------
- Built images produce `generated/build-artifact.json` and `generated/image-digest.txt`. CI consumes `build-artifact.json` as the single source of truth for SBOMs, vulnerability scans, and promotion by digest.
- Tag format: `<registry>/<repo>:<profile-slug>-<tag>` where `profile-slug` strips numeric prefixes (e.g., `20-00-data-science` -> `data-science`).

Development workflow notes
-------------------------
- Prefer using the generated `generated/Dockerfile` for iterative feature debugging; features can rely on `scripts/lib/helpers.sh` which is copied early into the generated image header.
- For macOS: install a modern Bash (`brew install bash`) or run scripts under `bash` (not `sh`/`zsh`) because some scripts require Bash 4+.

CI and release
--------------
- CI generates SBOMs (Syft) and vulnerability scans (Trivy) and uploads them as workflow artifacts. Releases are promoted by digest (no rebuild) and may be signed with Cosign if configured.

Where to go next
----------------
- Read `profiles/README.md` for profile naming conventions and examples.
- If you plan to reduce repository size, consider moving large files from `artefacts/` into GitHub Releases or an object store and keep only checksums in-repo.

Contact
-------
If you want me to implement any of the recommended changes (profile metadata, validators, devcontainer), tell me which item to start next.
