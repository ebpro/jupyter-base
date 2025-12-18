# Layout and workflow for Quarto documents and student notebooks

This document describes a recommended, practical layout and workflow to manage Quarto lecture sources, a shared/common Quarto configuration, and student-facing notebook environments using the devcontainer built from this repository.

## Goals
- Keep editable lecture sources on the host (easy editing and git workflows).
- Provide one shared, updatable Quarto configuration/template set available to all devcontainers.
- Separate generated artifacts from source to avoid accidental commits.
- Make it easy to render Quarto documents inside the devcontainer and to provide runnable notebook environments for students.

## Recommended host layout

Place course repositories and auxiliary folders on the host. Example structure:

~/projects/course-101/
- lectures/
  - lecture-01/
    - index.qmd
    - code/             # supporting code files
    - notebooks/        # instructor notebooks or converted qmd->ipynb
  - lecture-02/
- slides/              # generated slide outputs (optional)
- notebooks/           # notebook sources for students (if separate)
- _quarto.yml          # project-specific Quarto options

~/quarto-templates/    # OPTIONAL host clone of shared templates (see sync options)
~/quarto-output/       # optional host location for generated site/artifacts

The devcontainer will mount workspace folders into `~/local/*` inside the container (see mount examples below).

## Container layout (what `quarto-common` provides)

- `/home/jovyan/local/work/<project>` — host project mount or working copy for the instructor.
- `/home/jovyan/local/templates/quarto` — shared templates/config (cloned by `quarto-common` or mounted from host).
- `/home/jovyan/local/generated/<project>` — generated files (render outputs).
- `/home/jovyan/local/repos` — optional: git clones that notebooks may create or reference.

Keeping these locations consistent ensures scripts and students can reliably find templates and outputs.

## Devcontainer mounts — example

Add the following to your `devcontainer.json` or use equivalent docker-compose mounts when launching containers.

Example `devcontainer.json` snippet:

```
"mounts": [
  "source=/Users/you/projects/course-101,target=/home/jovyan/local/work/course-101,type=bind,consistency=cached",
  "source=/Users/you/quarto-templates,target=/home/jovyan/local/templates/quarto,type=bind,consistency=cached",
  "source=/Users/you/quarto-output/course-101,target=/home/jovyan/local/generated/course-101,type=bind,consistency=cached"
]
```

If you prefer the feature to clone templates, omit the second mount and let `quarto-common` clone `QUARTO_TEMPLATES_REPO` into `/home/jovyan/local/templates/quarto`.

## Quarto project configuration

Project `_quarto.yml` (example) referencing shared templates:

```yaml
project:
  type: website
  template: /home/jovyan/local/templates/quarto
output-dir: /home/jovyan/local/generated/course-101/lecture-01
```

Using an absolute `template:` path ensures Quarto always picks the shared templates regardless of current working dir.

## Commands: render and convert inside the devcontainer

Run these as the notebook user (`jovyan`) inside the container:

```
cd /home/jovyan/local/work/course-101/lectures/lecture-01
quarto render .
# or write output to the shared generated directory explicitly
quarto render --output-dir /home/jovyan/local/generated/course-101/lecture-01

# Convert qmd to ipynb (if you produce notebooks from your qmd)
quarto convert slide.qmd --to ipynb -o notebooks/slide.ipynb
```

For repeatable builds (CI or image builds) pin the templates repo to a tag and let the feature clone that tag during image build.

## Syncing and evolving shared templates

Several strategies are possible, pick the one matching your reproducibility and convenience needs:

- Host-managed Git repo (recommended for rapid dev):
  - Keep `~/quarto-templates` on your host and mount it into the container. Edit and push from host; container sees updates immediately.

- Feature-managed clone with optional sync helper (recommended for reproducible image builds):
  - Configure `quarto-common` with `QUARTO_TEMPLATES_REPO` and `QUARTO_TEMPLATES_REF` env vars.
  - At build/start the feature clones the configured ref into `/home/jovyan/local/templates/quarto`.
  - Provide a small helper script `~/bin/quarto-sync-templates` that students/instructors can run to pull updates at runtime.

- Submodule/subtree (project-level):
  - Add templates as a git submodule of the lecture repo when you want explicit commits in project history referencing the templates.

- Releases/tags in templates repo:
  - For reproducible images and CI, tag releases of `quarto-templates` and pin the feature to that tag. Update tag when you intend to roll out changes.

Security note: avoid running arbitrary install scripts from template repos at image build time unless you trust the source.

## Student environments (not Quarto): notebooks and runnable practice

Options for giving students runnable environments:

- Simple local containers (recommended for in-class use)
  - Build a single instructor image (this repository) and have each student run their own container mounting their project folder.
  - Example run command:
    ```bash
    docker run -it --rm -p 8888:8888 \
      -v ~/projects/course-101/student-01:/home/jovyan/local/work/course-101:cached \
      -v ~/quarto-templates:/home/jovyan/local/templates/quarto:cached \
      ghcr.io/ebpro/jupyter-base:quarto-lecture-dev-java-25-develop
    ```

- JupyterHub / managed multi-user platforms (recommended at scale)
  - Use DockerSpawner or Kubernetes to provide per-student servers. Store persistent home dirs for students.

- Binder / repo2docker / Codespaces
  - Quick, zero-admin approach for single-repo demos; less control for larger classes.

When using bind mounts, ensure students can write to mounted directories. If the host UID differs from the container `jovyan` UID, instruct students to run containers with `-u $(id -u):$(id -g)` or ensure group-writable mounts.

## Permissions and ownership tips

- `quarto-common` sets ownership of `/home/jovyan/local` to `${NB_UID}:${NB_GID}` during feature install. For bind mounts, the host file ownership prevails.
- If you need to fix permissions inside the container for a bind mount, you can run:
  ```bash
  sudo chown -R $(id -u jovyan):$(id -g jovyan) /home/jovyan/local
  ```
  Note: `chown` on some bind mounts may be restricted by the host filesystem.

## Example: making a new lecture from a template

1. Create lecture folder on host: `~/projects/course-101/lectures/lecture-03`.
2. Copy shared example into it:
   ```bash
   cp -a ~/quarto-templates/example-lecture/* ~/projects/course-101/lectures/lecture-03/
   ```
3. Open the devcontainer or start a container mounting the project.
4. Inside container: `cd /home/jovyan/local/work/course-101/lectures/lecture-03 && quarto render .`

## Troubleshooting

- Quarto reports `Jupyter: (None)`
  - Ensure the Miniforge/mamba `bin` is on PATH when Quarto runs (the repo's `quarto` wrapper should add `${CONDA_DIR}/bin` to PATH). Verify `which jupyter` points to the Miniforge prefix.

- Notebooks cannot write to mounted folders
  - Check host file permissions; consider running the container with the same UID as the host user, or set group-writable permissions and add the user to the group.

## Next steps you can ask me to do

- Add git-sync behavior into the `quarto-common` feature (clone at build, `quarto-sync-templates` helper).
- Add a concrete `devcontainer.json` example file into this repo for a course profile.
- Draft a short `docs/lectures.md` showing the instructor step-by-step workflow (I can create it from this layout).

---
Generated by the project tooling — keep this file with your repository root so instructors and maintainers can reference the canonical layout.
