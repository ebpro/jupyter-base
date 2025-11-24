#!/usr/bin/env bash
set -euo pipefail

echo "profile-minimal: writing features list to /tmp/profile-minimal-features"
cat > /tmp/profile-minimal-features <<'EOF'
_lib/checksum-verify
_lib/toolcache
base-apt
zsh-config
dev-tools
startup
docker-cli-helper
EOF

if [ "${RUN_SUBFEATURES:-false}" = "true" ]; then
  echo "profile-minimal: RUN_SUBFEATURES=true — executing sub-feature install scripts"
  for f in $(cat /tmp/profile-minimal-features); do
    script=.devcontainer/features/${f}/install.sh
    if [ -x "$script" ]; then
      echo "profile-minimal: running $script"
      /bin/bash "$script" || echo "profile-minimal: subfeature $f failed (continuing)"
    else
      echo "profile-minimal: no executable install script for $f, skipping"
    fi
  done
fi

echo "profile-minimal: done"
