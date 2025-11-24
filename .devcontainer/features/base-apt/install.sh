#!/usr/bin/env bash
set -euo pipefail

echo "base-apt: installing packages listed in /tmp/Artefacts/apt_packages_base (if present)"
if [ -f /tmp/Artefacts/apt_packages_base ]; then
  PKGS=$(grep -v -e "^#" -e "^$" /tmp/Artefacts/apt_packages_base | tr '\n' ' ' || true)
  PKGS=$(echo "$PKGS" | xargs || true)
  if [ -n "$PKGS" ]; then
    apt-get update
    apt-get install -y --no-install-recommends $PKGS || true
    rm -rf /var/lib/apt/lists/* || true
  fi
else
  echo "base-apt: /tmp/Artefacts/apt_packages_base not present; skipping"
fi

echo "base-apt: done"
