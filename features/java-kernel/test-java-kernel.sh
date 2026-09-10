#!/usr/bin/env bash
set -euo pipefail

echo "Running java-kernel feature tests"

NB_USER="${NB_USER:-jovyan}"

java_bin="$(command -v java || true)"
if [ -z "$java_bin" ]; then
  java_bin="/home/${NB_USER}/.sdkman/candidates/java/current/bin/java"
fi

if [ ! -x "$java_bin" ]; then
  echo "ERROR: java runtime not found" >&2
  exit 1
fi

"$java_bin" -version

kernel_dir="/usr/local/share/jupyter/kernels/java"
if [ -d "$kernel_dir" ]; then
  echo "Found IJava kernelspec at $kernel_dir"
else
  jupyter_bin="$(command -v jupyter || true)"
  if [ -z "$jupyter_bin" ]; then
    for candidate in "/home/${NB_USER}/miniforge3/bin/jupyter" "/usr/local/bin/jupyter"; do
      if [ -x "$candidate" ]; then
        jupyter_bin="$candidate"
        break
      fi
    done
  fi

  if [ -z "$jupyter_bin" ]; then
    echo "ERROR: IJava kernelspec not found and jupyter CLI is unavailable" >&2
    exit 1
  fi

  "$jupyter_bin" kernelspec list --json | python3 -c '
import json
import sys

kernels = json.load(sys.stdin)
if "java" not in kernels:
    raise SystemExit("ERROR: java kernelspec not registered")
'
fi

echo "java-kernel feature tests passed"
