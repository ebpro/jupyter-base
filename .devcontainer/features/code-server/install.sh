#!/usr/bin/env bash
set -euo pipefail

NB_USER=${NB_USER:-jovyan}
NB_UID=${NB_UID:-1001}
NB_GID=${NB_GID:-1001}
HOME_DIR="/home/${NB_USER}"

echo "code-server: installing code-server runtime"

# Ensure small prerequisites
apt-get update && apt-get install -y --no-install-recommends curl ca-certificates tar || true
rm -rf /var/lib/apt/lists/* || true

# Resolve version from Artefacts (workspace or /tmp)
CODE_SERVER_VERSION=""
if [ -f "${PWD}/Artefacts/versions.json" ]; then
  CODE_SERVER_VERSION=$(jq -r '.tools["code-server"] // empty' "${PWD}/Artefacts/versions.json" 2>/dev/null || true)
fi
if [ -z "${CODE_SERVER_VERSION}" ] && [ -f /tmp/versions.json ]; then
  CODE_SERVER_VERSION=$(jq -r '.tools["code-server"] // empty' /tmp/versions.json 2>/dev/null || true)
fi
if [ -z "${CODE_SERVER_VERSION}" ]; then
  echo "code-server: version not found in Artefacts or /tmp/versions.json; skipping" >&2
  exit 0
fi

# Determine arch
if [ -f "${PWD}/scripts/arch.sh" ]; then
  # shellcheck source=/dev/null
  source "${PWD}/scripts/arch.sh"
  ARCH=$(arch_map "${TARGETPLATFORM:-$(uname -m)}")
else
  case "$(uname -m)" in
    x86_64|X86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="amd64" ;;
  esac
fi

CODE_URL="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${ARCH}.tar.gz"

echo "code-server: downloading ${CODE_URL}"
curl -fsSLo /tmp/code-server.tar.gz "${CODE_URL}"

# Verify checksum if available
CHKSUM=""
if [ -f "${PWD}/Artefacts/checksums.json" ]; then
  CHKSUM=$(jq -r --arg t "code-server" --arg ver "${CODE_SERVER_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' "${PWD}/Artefacts/checksums.json" 2>/dev/null || true)
fi
if [ -z "${CHKSUM}" ] && [ -f /tmp/checksums.json ]; then
  CHKSUM=$(jq -r --arg t "code-server" --arg ver "${CODE_SERVER_VERSION}" --arg arch "${ARCH}" '.tools[$t].checksums[$ver][$arch] // empty' /tmp/checksums.json 2>/dev/null || true)
fi
if [ -n "${CHKSUM}" ]; then
  echo "${CHKSUM}  /tmp/code-server.tar.gz" > /tmp/code-server.sha256 && sha256sum -c /tmp/code-server.sha256 || true
fi

mkdir -p /opt/code-server
tar -xzf /tmp/code-server.tar.gz -C /opt/code-server --strip-components=1
rm -f /tmp/code-server.tar.gz
ln -s /opt/code-server/bin/code-server /usr/local/bin/code-server || true
chown -R ${NB_UID}:${NB_GID} /opt/code-server || true

echo "code-server: installed to /opt/code-server"

exit 0
