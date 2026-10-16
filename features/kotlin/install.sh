# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

# kotlin install
INSTALL_KOTLIN=${INSTALL_KOTLIN:-true}
INSTALL_KOTLIN_KERNEL=${INSTALL_KOTLIN_KERNEL:-false}

# ---------------------------------------------------------------------------
# kotlin-jupyter kernel (INSTALL_KOTLIN_KERNEL gate)
#
# Source of truth for the wheel URL and sha256 is the root checksums.json
# entry "tools.kotlin-jupyter" (lookup order: /tmp/checksums.json ->
# /tmp/artefacts/checksums.json -> /opt/solen/artefacts/checksums.json ->
# $FH_REPO_ROOT/checksums.json -> $PWD/checksums.json). The version below is
# the KERNEL PACKAGE release (PyPI 'kotlin-jupyter-kernel'); it is NOT the
# Kotlin language level of notebooks. The wheel bundles its own compiler
# runtime (2.4.0-dev-6891) and ignores the SDKMAN KOTLIN_VERSION pin.
# PyPI marks the package Development Status :: 4 - Beta. See README.md.
# ---------------------------------------------------------------------------
KOTLIN_KERNEL_CHECKSUM_TOOL="kotlin-jupyter"
KOTLIN_KERNEL_PYPI_PACKAGE="kotlin-jupyter-kernel"
KOTLIN_KERNEL_VERSION_DEFAULT="0.19.0.944"

# Which matrix entry turns the kernel gate on (used in failure messages so a
# red build names its consumer without archaeology).
kotlin_kernel_consumer_note() {
  echo "consumer: profiles/matrix/languages.yaml -> lang-kotlin (INSTALL_KOTLIN_KERNEL=true)"
}

# Map uname -m to the checksums.json arch keys (same mapping as
# fh_resolve_checksum / fh_verify_from_checksums).
kotlin_kernel_arch_key() {
  local uname_m
  uname_m=$(uname -m 2>/dev/null || echo "")
  case "$uname_m" in
    x86_64|X86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "$uname_m" ;;
  esac
}

# First existing checksums.json among the sanctioned build-time locations.
kotlin_kernel_checksums_file() {
  local candidates=(
    "/tmp/checksums.json"
    "/tmp/artefacts/checksums.json"
    "/opt/solen/artefacts/checksums.json"
    "${FH_REPO_ROOT:-/nonexistent-solen}/checksums.json"
    "${PWD}/checksums.json"
    "./checksums.json"
  )
  local p
  for p in "${candidates[@]}"; do
    if [ -f "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Read one field (url|sha) of the kotlin-jupyter entry via jq, python3 or
# python. Parameters are passed through the environment to keep the heredocs
# free of interpolation.
kotlin_kernel_json_field() {
  local file="$1" field="$2" tool="$3" version="$4" arch="$5"
  if command -v jq >/dev/null 2>&1; then
    case "$field" in
      url)
        jq -r --arg t "$tool" '.tools[$t].archive_url_template // empty' "$file"
        ;;
      sha)
        jq -r --arg t "$tool" --arg v "$version" --arg a "$arch" \
          '.tools[$t].checksums[$v][$a] // .tools[$t].checksums[$v].amd64 // .tools[$t].checksums[$v].arm64 // empty' "$file"
        ;;
      *) return 2 ;;
    esac
    return 0
  fi
  local pycmd=""
  if command -v python3 >/dev/null 2>&1; then
    pycmd=python3
  elif command -v python >/dev/null 2>&1; then
    pycmd=python
  else
    return 3
  fi
  KQ_FILE="$file" KQ_FIELD="$field" KQ_TOOL="$tool" KQ_VERSION="$version" KQ_ARCH="$arch" "$pycmd" - <<'PY'
import json
import os

with open(os.environ["KQ_FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
tool = data.get("tools", {}).get(os.environ["KQ_TOOL"], {})
if os.environ["KQ_FIELD"] == "url":
    print(tool.get("archive_url_template") or "")
else:
    entry = (tool.get("checksums") or {}).get(os.environ["KQ_VERSION"])
    value = ""
    if isinstance(entry, dict):
        value = entry.get(os.environ["KQ_ARCH"]) or entry.get("amd64") or entry.get("arm64") or ""
    elif isinstance(entry, str):
        value = entry
    print(value)
PY
}

# Bounded retry (max 3 attempts, exponential backoff) for TRANSIENT network
# failures only. A checksum mismatch is verified after this returns and must
# never be retried into a pass.
kotlin_kernel_fetch_wheel() {
  local url="$1" dest="$2"
  local max_attempts=3
  local delay="${KOTLIN_KERNEL_RETRY_DELAY:-2}"
  local attempt
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if curl -fsSL --connect-timeout 20 --max-time 1800 -o "$dest" "$url"; then
      return 0
    fi
    rm -f "$dest"
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "kotlin: wheel fetch attempt ${attempt}/${max_attempts} failed; retrying in ${delay}s" >&2
      if [ "$delay" -gt 0 ]; then sleep "$delay"; fi
      delay=$((delay * 2))
    fi
  done
  return 1
}

kotlin_kernel_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$f" | awk '{print $2}'
  else
    return 1
  fi
}

kotlin_install_kernel() {
  local version="${KOTLIN_KERNEL_VERSION:-$KOTLIN_KERNEL_VERSION_DEFAULT}"
  local wheel="kotlin_jupyter_kernel-${version}-py3-none-any.whl"
  local consumer
  consumer="$(kotlin_kernel_consumer_note)"

  # Interpreter convention shared with features/jupyter-kernels and
  # features/java-kernel: when present, the kernelspec MUST be registered by
  # the same interpreter whose prefix the notebook server serves (miniforge
  # base). Profiles whose closure carries no python-conda (lang-kotlin) have
  # no miniforge python; for those the installer resolves `python3` on PATH
  # (installed by python-base) and derives the kernelspec location from that
  # interpreter's own sysconfig data prefix, so the post-install assertion
  # tracks the interpreter that actually performed the registration.
  # Neither available -> hard fail: a silently skipped kernel is the
  # silent-skip failure class this gate exists to prevent.
  local nb_user="${NB_USER:-jovyan}"
  local nb_uid="${NB_UID:-1001}"
  local nb_gid="${NB_GID:-1001}"
  local home_dir="${HOME_DIR:-/home/${nb_user}}"
  local conda_dir="${CONDA_DIR:-${home_dir}/miniforge3}"
  local python_exec="${conda_dir}/bin/python"
  local interpreter_is_fallback="false"

  if [ ! -x "$python_exec" ]; then
    local system_python
    system_python="$(command -v python3 2>/dev/null || true)"
    if [ -n "$system_python" ] && [ -x "$system_python" ]; then
      echo "kotlin: ${python_exec} unavailable; registering the kernel with python3 from PATH (${system_python})"
      python_exec="$system_python"
      interpreter_is_fallback="true"
    else
      echo "kotlin: FAILED to install ${KOTLIN_KERNEL_PYPI_PACKAGE} ${version}: neither the notebook stack interpreter ${conda_dir}/bin/python nor an executable python3 on PATH is available. The kernelspec must be registered by an interpreter whose jupyter prefix the notebook server resolves; refusing to proceed without one. ${consumer}" >&2
      exit 1
    fi
  fi

  # Kernelspec location. Conda branch: the historical fixed path, unchanged.
  # Fallback branch: the resolved interpreter's sysconfig data path -- Debian
  # system pip lands the wheel's DATA_FILES under /usr/local/share/jupyter,
  # not under ${conda_dir} -- so the idempotency probe and the post-install
  # assertion look where this interpreter actually wrote the spec.
  local spec_dir
  if [ "$interpreter_is_fallback" = "true" ]; then
    local data_prefix
    data_prefix="$("$python_exec" -c 'import sysconfig; print(sysconfig.get_path("data"))' 2>/dev/null)" || data_prefix=""
    if [ -z "$data_prefix" ]; then
      echo "kotlin: FAILED to install ${KOTLIN_KERNEL_PYPI_PACKAGE} ${version}: could not derive the sysconfig data path from the fallback interpreter ${python_exec}; the kernelspec location would be unverifiable. ${consumer}" >&2
      exit 1
    fi
    spec_dir="${data_prefix}/share/jupyter/kernels/kotlin"
  else
    spec_dir="${conda_dir}/share/jupyter/kernels/kotlin"
  fi

  # Idempotency: module importable and kernelspec already written -> skip the
  # ~80 MB fetch entirely (mirrors the 'compiler already present' branch).
  if "$python_exec" -c "import run_kotlin_kernel" >/dev/null 2>&1 \
    && [ -f "${spec_dir}/kernel.json" ]; then
    echo "kotlin: kernel already present (module importable, kernelspec registered)"
    return 0
  fi

  # Resolve URL + expected sha256 from checksums.json. An unverified download
  # is not acceptable: no digest, no fetch.
  local arch url sha expected
  arch="$(kotlin_kernel_arch_key)"
  url="${KOTLIN_KERNEL_WHEEL_URL:-}"
  sha=""
  if command -v fh_resolve_checksum >/dev/null 2>&1; then
    sha="$(fh_resolve_checksum "$KOTLIN_KERNEL_CHECKSUM_TOOL" "$version" 2>/dev/null || true)"
  fi
  local csf
  csf="$(kotlin_kernel_checksums_file || true)"
  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    if [ -n "$csf" ]; then
      sha="$(kotlin_kernel_json_field "$csf" sha "$KOTLIN_KERNEL_CHECKSUM_TOOL" "$version" "$arch" || true)"
    fi
  fi
  if [ -z "$url" ] && [ -n "$csf" ]; then
    url="$(kotlin_kernel_json_field "$csf" url "$KOTLIN_KERNEL_CHECKSUM_TOOL" "$version" "$arch" || true)"
  fi

  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    echo "kotlin: FAILED to install ${KOTLIN_KERNEL_PYPI_PACKAGE} ${version}: no pinned sha256 for tools.${KOTLIN_KERNEL_CHECKSUM_TOOL}.checksums.${version} (searched: /tmp/checksums.json, /tmp/artefacts/checksums.json, /opt/solen/artefacts/checksums.json, \$FH_REPO_ROOT/checksums.json, \$PWD/checksums.json). Refusing an unverified download. ${consumer}" >&2
    exit 1
  fi
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "kotlin: FAILED to install ${KOTLIN_KERNEL_PYPI_PACKAGE} ${version}: no wheel URL available (set KOTLIN_KERNEL_WHEEL_URL or tools.${KOTLIN_KERNEL_CHECKSUM_TOOL}.archive_url_template in checksums.json; PyPI serves no GitHub Releases and the files.pythonhosted.org path is content-hashed, so it cannot be templated from the version). Expected sha256: ${sha}. ${consumer}" >&2
    exit 1
  fi
  expected="$sha"

  echo "kotlin: installing ${KOTLIN_KERNEL_PYPI_PACKAGE} ${version} (kernel package version, NOT the notebook Kotlin level; wheel bundles its own compiler runtime) from ${url}"

  local tmpdir wheel_path actual
  tmpdir="$(mktemp -d)"
  wheel_path="${tmpdir}/${wheel}"
  if ! kotlin_kernel_fetch_wheel "$url" "$wheel_path"; then
    rm -rf "$tmpdir"
    echo "kotlin: FAILED to download '${wheel}' (pinned version ${version}) from ${url} after 3 attempts. This install performs a build-time network fetch from files.pythonhosted.org; aborting the build rather than shipping an image that advertises a kotlin kernel it does not have. Expected sha256: ${expected}. ${consumer}" >&2
    exit 1
  fi

  if ! actual="$(kotlin_kernel_sha256 "$wheel_path")" || [ -z "$actual" ]; then
    rm -rf "$tmpdir"
    echo "kotlin: FAILED to verify '${wheel}': no sha256 tool available (sha256sum/shasum/openssl). Expected sha256: ${expected}. ${consumer}" >&2
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    rm -rf "$tmpdir"
    # Deliberately NOT retried: a mismatched digest is a content failure, and
    # retrying could turn a corrupt or substituted artefact into a 'pass'.
    echo "kotlin: FAILED checksum verification for '${wheel}' (pinned version ${version}): expected sha256 ${expected} (tools.${KOTLIN_KERNEL_CHECKSUM_TOOL} in checksums.json), got ${actual}. Refusing to install an artefact that does not match the pinned digest; not retrying. ${consumer}" >&2
    exit 1
  fi
  echo "kotlin: wheel verified: sha256 ${actual}"

  # --no-index: nothing to resolve remotely (local wheel only).
  # --no-deps: upstream semantics (its conda recipe does the same; the
  # package declares no requires_dist and the runtime deps ship inside the
  # wheel/kernel spec).
  # --break-system-packages: ONLY when the resolved interpreter's stdlib
  # carries the PEP 668 EXTERNALLY-MANAGED marker (Ubuntu 24.04 system
  # python3; conda's python does not, so the conda path stays exactly as
  # before). Same in-repo precedent as features/postgresql-client/install.sh.
  local pip_flags=(--no-index --no-deps)
  if "$python_exec" -c 'import os, sysconfig, sys; sys.exit(0 if os.path.isfile(os.path.join(sysconfig.get_path("stdlib"), "EXTERNALLY-MANAGED")) else 1)' 2>/dev/null; then
    pip_flags+=(--break-system-packages)
  fi
  if ! "$python_exec" -m pip install "${pip_flags[@]}" "$wheel_path"; then
    rm -rf "$tmpdir"
    echo "kotlin: FAILED 'pip install ${pip_flags[*]} ${wheel}' with interpreter ${python_exec}; aborting rather than shipping an image that advertises a kotlin kernel it does not have. ${consumer}" >&2
    exit 1
  fi
  rm -rf "$tmpdir"

  # The wheel's own generated kernel.json (DATA_FILES:
  # share/jupyter/kernels/kotlin) is what registers the spec. Do NOT
  # hand-write one, and do NOT run 'fix-kernelspec-location' (copies to the
  # user data dir -> /root/.local/share/jupyter under a root build, invisible
  # to ${nb_user}) or 'add-kernel' (registers 'kotlin_<name>', never plain
  # 'kotlin'). spec_dir was derived from the resolved interpreter above.
  if [ ! -f "${spec_dir}/kernel.json" ]; then
    echo "kotlin: FAILED: pip install succeeded but no kernelspec at ${spec_dir}/kernel.json; a notebook server could not resolve the 'kotlin' kernel. ${consumer}" >&2
    exit 1
  fi

  # Payload completeness: the spec's argv ('python -m run_kotlin_kernel')
  # resolves jars relative to the module's own __file__, so the module dir
  # must ship jars/ and config/jar_args.json with the main jar inside.
  if ! "$python_exec" - "${spec_dir}" <<'PY'
import json
import os
import run_kotlin_kernel
import sys

spec_dir = sys.argv[1]
assert os.path.isfile(os.path.join(spec_dir, "kernel.json")), "kernel.json missing"

mod_dir = os.path.dirname(os.path.abspath(run_kotlin_kernel.__file__))
jars = os.path.join(mod_dir, "jars")
cfg = os.path.join(mod_dir, "config", "jar_args.json")
assert os.path.isdir(jars), "missing %s" % jars
assert os.path.isfile(cfg), "missing %s" % cfg

with open(cfg, encoding="utf-8") as fh:
    main_jar = json.load(fh)["mainJar"]
assert os.path.isfile(os.path.join(jars, main_jar)), "missing main jar %s in %s" % (main_jar, jars)
print("kotlin: kernel payload OK: module %s, main jar %s" % (mod_dir, main_jar))
PY
  then
    echo "kotlin: FAILED: installed kernel payload is incomplete (run_kotlin_kernel jars/config). ${consumer}" >&2
    exit 1
  fi

  # Runtime caches the kernel writes as ${nb_user}: ~/.jupyter_kotlin (library
  # resolution, 'cache' subdir) and ~/.m2/repository (@DependsOn / %use).
  # If root creates them, user dependency resolution breaks at runtime.
  mkdir -p "${home_dir}/.jupyter_kotlin/cache" "${home_dir}/.m2/repository"
  if [ "$(id -u)" = "0" ]; then
    chown -R "${nb_uid}:${nb_gid}" "${home_dir}/.jupyter_kotlin" "${home_dir}/.m2" >/dev/null 2>&1 || true
  fi

  # JVM selection at kernel start: KOTLIN_JUPYTER_JAVA_EXECUTABLE ->
  # KOTLIN_JUPYTER_JAVA_HOME -> JAVA_HOME -> bare 'java'. The generated
  # Dockerfile exports JAVA_HOME as an image-level ENV
  # (/home/jovyan/.sdkman/candidates/java/current), which the notebook server
  # inherits without needing shell init; verify it resolves here so a
  # dangling 'current' link is visible in the build log, not at first cell.
  if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
    echo "kotlin: kernel JVM will resolve via JAVA_HOME=${JAVA_HOME}"
  else
    echo "kotlin: WARNING JAVA_HOME='${JAVA_HOME:-<unset>}' has no executable bin/java; the kernel will fall back to bare 'java' from PATH at runtime"
  fi

  echo "kotlin: kernel installed (kernelspec ${spec_dir}; language level is the wheel's bundled compiler, not KOTLIN_VERSION)"
}

# Normalise once to lowercase: profile options declared as YAML booleans are
# stringified as "True"/"False" by the generator (str(True)), which would fail
# the case-sensitive lowercase comparisons below and silently skip installation.
INSTALL_KOTLIN_LC="${INSTALL_KOTLIN,,}"
INSTALL_KOTLIN_KERNEL_LC="${INSTALL_KOTLIN_KERNEL,,}"

echo "kotlin: install_compiler=$INSTALL_KOTLIN_LC kernel=$INSTALL_KOTLIN_KERNEL_LC"

if [ "$INSTALL_KOTLIN_LC" = "true" ]; then
  if command -v kotlinc >/dev/null 2>&1; then
    echo "kotlin: compiler already present"
  else
    # Source SDKMAN init (installed by java-sdkman feature in same RUN layer)
    if [ -s "${HOME}/.sdkman/bin/sdkman-init.sh" ]; then
      set +u
      # shellcheck disable=SC1091
      source "${HOME}/.sdkman/bin/sdkman-init.sh"
      set -u
    fi

    KOTLIN_VERSION="${KOTLIN_VERSION:-}"

    # SDKMAN may be installed but not on PATH in non-login shells.
    # Source the init script to make `sdk` available.
    if [ -f "${HOME}/.sdkman/bin/sdkman-init.sh" ]; then
      set +u; source "${HOME}/.sdkman/bin/sdkman-init.sh"; set -u
    elif [ -f "/home/jovyan/.sdkman/bin/sdkman-init.sh" ]; then
      set +u; source "/home/jovyan/.sdkman/bin/sdkman-init.sh"; set -u
    fi

    if command -v sdk >/dev/null 2>&1; then
      # Compose the SDKMAN command once: pinned version when requested,
      # otherwise the SDKMAN current candidate.
      if [ -n "${KOTLIN_VERSION}" ]; then
        KOTLIN_SDK_CMD="sdk install kotlin ${KOTLIN_VERSION}"
      else
        KOTLIN_SDK_CMD="sdk install kotlin"
      fi

      # `sdk install` fetches candidate metadata and the distribution from
      # the SDKMAN CDN and repo1.maven.apache.org, so this step is
      # network-dependent. A failure used to be swallowed by `|| true`,
      # yielding green builds whose images contained no kotlinc while
      # feature.json advertised it via `kotlinc -version`. Fail loudly at
      # the point of failure instead.
      if ! su - "${NB_USER:-jovyan}" -s /bin/bash -lc "set +u; [ -s \"\$HOME/.sdkman/bin/sdkman-init.sh\" ] && source \"\$HOME/.sdkman/bin/sdkman-init.sh\" >/dev/null 2>&1 || true; ${KOTLIN_SDK_CMD}"; then
        echo "kotlin: FAILED '${KOTLIN_SDK_CMD}' (version requested: ${KOTLIN_VERSION:-<sdkman current>}). This install performs a network fetch (SDKMAN CDN + repo1.maven); aborting the build at the point of failure rather than shipping an image without kotlinc." >&2
        exit 1
      fi
    else
      echo "kotlin: please install Kotlin compiler in base image or enable sdk"
    fi
  fi
fi

if [ "$INSTALL_KOTLIN_KERNEL_LC" = "true" ]; then
  kotlin_install_kernel
fi

echo "kotlin: done"
