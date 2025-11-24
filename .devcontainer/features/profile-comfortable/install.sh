#!/usr/bin/env bash
set -euo pipefail

echo "profile-comfortable: writing features list to /tmp/profile-comfortable-features"
cat > /tmp/profile-comfortable-features <<'EOF'
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
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-comfortable: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-comfortable-features); do
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-comfortable: running $script"
      /bin/bash "$script" || echo "profile-comfortable: subfeature $f failed (continuing)"
    else
      echo "profile-comfortable: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-comfortable: done"
