# kotlin

**Purpose:** Kotlin compiler via SDKMAN, plus an optional, checksum-pinned
Kotlin Jupyter kernel behind `INSTALL_KOTLIN_KERNEL`.

## Description

Two largely independent pieces:

1. **CLI compiler** — `sdk install kotlin ${KOTLIN_VERSION}` through SDKMAN
   (provided by `java-sdkman`). Failure is loud: the installer exits non-zero
   rather than shipping an image without `kotlinc`.
2. **Jupyter kernel** (`INSTALL_KOTLIN_KERNEL=true`) — installs the PyPI
   package **`kotlin-jupyter-kernel`**, pinned to **`0.19.0.944`** in the repo
   root `checksums.json` under `tools.kotlin-jupyter`, into the *resolved*
   kernel interpreter: the notebook stack's own miniforge python
   (`${CONDA_DIR:-${HOME_DIR:-/home/$NB_USER}/miniforge3}/bin/python`) when
   executable, otherwise `python3` on `PATH` (profiles without `python-conda`
   in their closure, e.g. `lang-kotlin`); if neither exists the installer
   fails closed. On the `python3` fallback the kernelspec location is derived
   from that interpreter's `sysconfig` data prefix and pip gains
   `--break-system-packages` only when its stdlib carries the PEP 668
   `EXTERNALLY-MANAGED` marker. Both paths install with
   `pip install --no-index --no-deps`. The wheel's bundled
   `share/jupyter/kernels/kotlin` payload is what registers the kernelspec;
   its argv is `python -m run_kotlin_kernel {connection_file}` (verified
   against the actual wheel).

### Read this before using the kernel

These facts were accepted deliberately; do not treat them as surprises:

- **The kernel bundles a dev-build compiler.** The wheel embeds
  `kotlin-script-runtime-2.4.0-dev-6891.jar` alongside
  `kotlin-stdlib-2.3.10-RC` / `kotlin-reflect-2.3.10-RC`. The notebook's
  Kotlin **language level is governed by the kernel release**, **not** by
  `KOTLIN_VERSION` — `KOTLIN_VERSION` only pins the SDKMAN CLI compiler, and
  the two versions are independent by design.
- **The package is Beta.** PyPI marks `kotlin-jupyter-kernel`
  `Development Status :: 4 - Beta`. Pin bumps should be reviewed against
  upstream (Kotlin/kotlin-jupyter publishes **no GitHub Releases** and **no
  sdist**; PyPI is the only source, and the `files.pythonhosted.org` URL is
  content-hashed, so it cannot be templated from the version).
- **Installation performs a build-time ~80 MB download** from
  `files.pythonhosted.org`, verified against the sha256 in `checksums.json`.
  A fetch failure (after 3 bounded retries for transient errors) or a digest
  mismatch **fails the build loudly by design**; a digest mismatch is never
  retried, because a retry that could land a matching artefact would turn a
  content failure into a pass. No pinned digest, no fetch.
- **`fix-kernelspec-location` and `add-kernel` are NOT used.** The former
  copies kernels into the *invoking user's* data dir — under a root build
  that means `/root/.local/share/jupyter/...`, invisible to `${NB_USER}`.
  The latter registers `kotlin_<name>`, never the plain `kotlin` spec the
  profile advertises. `kernel.json` is never hand-written either; the wheel
  places it under `<prefix>/share/jupyter/kernels/kotlin` where the notebook
  server resolves it.
- **JVM precedence at kernel start** (verified from the wheel's
  `kotlin_kernel/env_names.py` and `run_kotlin_kernel/run_kernel.py`):
  `KOTLIN_JUPYTER_JAVA_EXECUTABLE` → `KOTLIN_JUPYTER_JAVA_HOME` →
  `JAVA_HOME` → bare `java` from `PATH`. The generated Dockerfile exports
  `JAVA_HOME=/home/jovyan/.sdkman/candidates/java/current` as an image-level
  ENV, which the notebook server inherits without shell init; the installer
  prints a diagnostic if that link does not resolve.
- **Runtime dependency resolution needs network at *runtime*, never at
  build time.** `%use` / `@DependsOn` fetch from Maven Central/JitPack when
  the cell runs; the build never executes such cells. `~/.jupyter_kotlin/cache`
  and `~/.m2/repository` are pre-created and owned by `${NB_USER}` so the
  kernel can write them.
- **`--no-deps` is upstream semantics.** The wheel declares no
  `requires_dist`, and upstream's own conda recipe installs it the same way.
  `--no-index` keeps the verified local wheel from touching the resolver.

## Dependencies

- `java-sdkman` (compiler + `JAVA_HOME` candidate link)
- for kernel installs: the notebook stack (conda/miniforge base at
  `CONDA_DIR`) when present, otherwise any executable `python3` on `PATH`
  (provided by `python-base`'s `python3`/`python3-pip`). Miniforge is not
  the sole supported interpreter.

## Usage

Enabled for the `lang-kotlin` profile via
`profiles/matrix/languages.yaml` (`INSTALL_KOTLIN: true`,
`INSTALL_KOTLIN_KERNEL: true`). Gate values are normalised with `${VAR,,}`,
so `true`/`True`/`TRUE` all enter. Re-pin by updating
`checksums.json tools.kotlin-jupyter` (version, URL, digests) and the
`KOTLIN_KERNEL_VERSION` default here; both are kept consistent by
`tests/test_kotlin_kernel_contract.py`.

## Options

| Option | Default | Meaning |
|---|---|---|
| `INSTALL_KOTLIN` | `true` | Install the SDKMAN CLI compiler (`kotlinc`). |
| `KOTLIN_VERSION` | SDKMAN current | Pins **only** the CLI compiler; does NOT affect the notebook language level. |
| `INSTALL_KOTLIN_KERNEL` | `false` | Install the kotlin-jupyter kernel (build-time ~80 MB verified download). |
| `KOTLIN_KERNEL_VERSION` | `0.19.0.944` | Kernel **package** release (PyPI), mirrored in `checksums.json`; NOT the Kotlin language level. Uppercase name by design: it is independent of the parked flat `version` options. |
| `KOTLIN_KERNEL_WHEEL_URL` | *(empty)* | Direct wheel URL override; empty resolves `tools.kotlin-jupyter.archive_url_template`. The pinned sha256 is enforced either way. |
| `install_kotlin_compiler` / `install_kotlin_kernel` | `true` / `false` | devcontainer-spec option mirrors of the two gates above. |

## Post-install check

`feature.json` runs one combined `postInstallCheck` (solen accepts one dict
per feature): always `kotlinc -version`, and when
`INSTALL_KOTLIN_KERNEL=true`, `jupyter_client.kernelspec.KernelSpecManager().get_kernel_spec("kotlin")`
plus payload assertions (`jars/`, `config/jar_args.json`, the `mainJar`
file). When the gate is false it prints an explicit skip line instead of
asserting kernel state.
