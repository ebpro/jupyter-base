#!/usr/bin/env bash
set -euo pipefail

if [ "${DEVCONTAINER_NODE_INSTALL_VOLTA:-false}" = "true" ]; then
  echo "node: installing Volta (user-local)"
  su - ${NB_USER:-jovyan} -c "curl https://get.volta.sh | bash -s -- --skip-setup" || true
  echo "node: Volta installed (may require new shell to take effect)"
else
  echo "node: installing nodejs/npm from apt (may be older version)"
  apt-get update && apt-get install -y --no-install-recommends nodejs npm || true
  rm -rf /var/lib/apt/lists/* || true
fi

echo "node: done"
