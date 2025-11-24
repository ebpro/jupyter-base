#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

if [ ! -f /tmp/codeserver_extensions ]; then
  echo "codeserver-extensions: /tmp/codeserver_extensions not present; skipping"
  exit 0
fi

echo "codeserver-extensions: reading extensions from /tmp/codeserver_extensions"
while IFS= read -r ext; do
  ext=$(echo "$ext" | sed -e 's/^#.*$//' -e 's/^\s*//' -e 's/\s*$//')
  if [ -z "$ext" ]; then
    continue
  fi
  echo "codeserver-extensions: would install extension $ext (requires code-server CLI at runtime)"
done < /tmp/codeserver_extensions

echo "codeserver-extensions: finished (note: actual install requires code-server runtime to be present)"
