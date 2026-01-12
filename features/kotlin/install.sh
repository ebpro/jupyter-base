#!/usr/bin/env bash
set -euo pipefail

# kotlin install skeleton
INSTALL_KOTLIN=${INSTALL_KOTLIN:-true}
INSTALL_KOTLIN_KERNEL=${INSTALL_KOTLIN_KERNEL:-false}

echo "kotlin: install_compiler=$INSTALL_KOTLIN kernel=$INSTALL_KOTLIN_KERNEL"

if [ "$INSTALL_KOTLIN" = "true" ]; then
  if command -v kotlinc >/dev/null 2>&1; then
    echo "kotlin: compiler already present"
  else
    if command -v sdk >/dev/null 2>&1; then
      sdk install kotlin || true
    else
      echo "kotlin: please install Kotlin compiler in base image or enable sdk"
    fi
  fi
fi

if [ "$INSTALL_KOTLIN_KERNEL" = "true" ]; then
  echo "kotlin: installing kotlin-jupyter kernel (please provide ARTIFACTS or release URL)"
  # Placeholder: download kernel release or build from source
fi

echo "kotlin: done"
