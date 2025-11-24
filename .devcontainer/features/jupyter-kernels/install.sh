#!/usr/bin/env bash
set -euo pipefail

echo "jupyter-kernels: installing zsh_jupyter_kernel and bash_kernel if available"
if python3 -c "import importlib; print(importlib.util.find_spec('zsh_jupyter_kernel') is not None)" 2>/dev/null | grep -q True; then
  python3 -m zsh_jupyter_kernel.install --sys-prefix || true
else
  echo "jupyter-kernels: zsh_jupyter_kernel not installed in interpreter; skipping"
fi

if python3 -c "import importlib; print(importlib.util.find_spec('bash_kernel') is not None)" 2>/dev/null | grep -q True; then
  python3 -m bash_kernel.install --sys-prefix || true
else
  echo "jupyter-kernels: bash_kernel not installed in interpreter; skipping"
fi

echo "jupyter-kernels: done"
