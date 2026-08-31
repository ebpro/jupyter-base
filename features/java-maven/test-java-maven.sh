#!/usr/bin/env bash
set -euo pipefail

echo "Running java-maven feature tests"

if command -v mvn >/dev/null 2>&1; then
  mvn -v
else
  echo "ERROR: mvn (Maven) not found" >&2
  exit 1
fi

echo "java-maven feature tests passed"
