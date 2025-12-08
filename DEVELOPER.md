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
- `profiles/` - profile definitions; each profile composes a set of `features`
- `features/` - reusable feature installers used to assemble images
- `scripts/` - generators and helpers used by `build.sh`
- `Artefacts/` - pre-baked artifacts (conda pkgs, TeXLive, etc.) referenced by images
- `Archive/` - legacy Dockerfiles/installers kept for reference
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

Tagging and artifacts
---------------------
- Built images produce `build-artifact.json` and `image-digest.txt` in the workspace. CI consumes `build-artifact.json` as the single source of truth for SBOMs, vulnerability scans, and promotion by digest.
- Tag format: `<registry>/<repo>:<profile-slug>-<tag>` where `profile-slug` strips numeric prefixes (e.g., `20-00-data-science` -> `data-science`).

Development workflow notes
-------------------------
- Prefer using the generated `Dockerfile.generated` for iterative feature debugging; features can rely on `shared/_lib/helpers.sh` which is copied early into the generated image header.
- For macOS: install a modern Bash (`brew install bash`) or run scripts under `bash` (not `sh`/`zsh`) because some scripts require Bash 4+.

CI and release
--------------
- CI generates SBOMs (Syft) and vulnerability scans (Trivy) and uploads them as workflow artifacts. Releases are promoted by digest (no rebuild) and may be signed with Cosign if configured.

Where to go next
----------------
- Read `profiles/README.md` for profile naming conventions and examples.
- If you plan to reduce repository size, consider moving large files from `Artefacts/` into GitHub Releases or an object store and keep only checksums in-repo.

Contact
-------
If you want me to implement any of the recommended changes (profile metadata, validators, devcontainer), tell me which item to start next.
