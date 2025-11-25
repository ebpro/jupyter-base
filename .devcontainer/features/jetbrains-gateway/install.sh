# Auto-inserted by scripts/inject_prebaked_helpers.sh
# Source shared feature helpers (prebaked into image) or fall back to repository helper
if [ -n "${FEATURE_HELPERS_DIR:-}" ] && [ -f "${FEATURE_HELPERS_DIR}/helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "${FEATURE_HELPERS_DIR}/helpers.sh"
elif [ -f "../../../scripts/feature_helpers.sh" ]; then
  # shellcheck disable=SC1091
  source "../../../scripts/feature_helpers.sh"
fi
#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "jetbrains-gateway: installing openssh-server (if start requested)"

if ! command -v sshd >/dev/null 2>&1; then
  apt-get update && apt-get install -y --no-install-recommends openssh-server || true
fi

# Ensure sshd runtime dirs
mkdir -p /var/run/sshd

# Basic sshd_config tweaks
if ! grep -q "GatewayPorts" /etc/ssh/sshd_config 2>/dev/null; then
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
  echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
  echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
  echo "UsePAM yes" >> /etc/ssh/sshd_config
fi

# Helper to start sshd in foreground (useful for entrypoint or compose)
cat > /usr/local/bin/start-sshd <<'EOF'
#!/usr/bin/env bash
set -e
mkdir -p /var/run/sshd
exec /usr/sbin/sshd -D
EOF
chmod +x /usr/local/bin/start-sshd || true

# If public key(s) provided via env GATEWAY_PUBLIC_KEYS, populate authorized_keys
if [ -n "${GATEWAY_PUBLIC_KEYS:-}" ]; then
  mkdir -p "${HOME_DIR}/.ssh"
  echo "${GATEWAY_PUBLIC_KEYS}" > "${HOME_DIR}/.ssh/authorized_keys"
  chown -R ${NB_UID}:${NB_GID} "${HOME_DIR}/.ssh"
  chmod 700 "${HOME_DIR}/.ssh"
  chmod 600 "${HOME_DIR}/.ssh/authorized_keys"
  echo "jetbrains-gateway: populated authorized_keys from GATEWAY_PUBLIC_KEYS"
fi

echo "jetbrains-gateway: installed start-sshd helper at /usr/local/bin/start-sshd"
