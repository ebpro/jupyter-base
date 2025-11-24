#!/usr/bin/env bash
set -euo pipefail

echo "profile-data: writing features list to /tmp/profile-data-features"
cat > /tmp/profile-data-features <<'EOF'
base-apt
zsh-config
dev-tools
startup
docker-cli-helper
node
lsp-tools
gh-cli
git-lfs
prompt-helpers
python-conda
pip-requirements
jupyter-kernels
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-data: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-data-features); do
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-data: running $script"
      /bin/bash "$script" || echo "profile-data: subfeature $f failed (continuing)"
    else
      echo "profile-data: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-data: done"
