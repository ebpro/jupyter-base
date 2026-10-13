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

# kotlin install skeleton
INSTALL_KOTLIN=${INSTALL_KOTLIN:-true}
INSTALL_KOTLIN_KERNEL=${INSTALL_KOTLIN_KERNEL:-false}

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
  echo "kotlin: installing kotlin-jupyter kernel (please provide ARTIFACTS or release URL)"
  # Placeholder: download kernel release or build from source
fi

echo "kotlin: done"
