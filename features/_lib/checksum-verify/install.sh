#!/usr/bin/env bash
set -euo pipefail

# Simple helper that verifies a single sha256 checksum string against a file.
# Usage: verify-artifact <sha256> <file>
cat > /usr/local/bin/verify-artifact <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "Usage: verify-artifact <sha256> <file>" >&2
  exit 2
fi
sha=$1
file=$2
tmp=$(mktemp)
echo "$sha  $file" > "$tmp"
sha256sum -c "$tmp"
rc=$?
rm -f "$tmp"
exit $rc
EOF

chmod +x /usr/local/bin/verify-artifact || true

# Helper that looks up a checksum from a checksums.json and verifies a file.
# Usage: verify-from-checksums <tool> <version> <arch> <file>
# The script looks for /tmp/checksums.json (image build path) or
# Artefacts/checksums.json in the repository (devcontainer context).
cat > /usr/local/bin/verify-from-checksums <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -ne 4 ]; then
  echo "Usage: verify-from-checksums <tool> <version> <arch> <file>" >&2
  exit 2
fi
tool=$1
ver=$2
arch=$3
file=$4

# Prefer /tmp/checksums.json (used during image builds), fallback to local Artefacts
if [ -f /tmp/checksums.json ]; then
  checksums=/tmp/checksums.json
elif [ -f Artefacts/checksums.json ]; then
  checksums=Artefacts/checksums.json
else
  echo "No checksums.json found at /tmp/checksums.json or Artefacts/checksums.json" >&2
  exit 3
fi

sha=$(jq -r --arg t "$tool" --arg ver "$ver" --arg arch "$arch" '.tools[$t].checksums[$ver][$arch] // empty' "$checksums" 2>/dev/null || true)
if [ -z "$sha" ]; then
  echo "Checksum not found for ${tool} ${ver} ${arch} in ${checksums}" >&2
  exit 4
fi

verify-artifact "$sha" "$file"
exit $?
EOF

chmod +x /usr/local/bin/verify-from-checksums || true

echo "checksum-verify: installed /usr/local/bin/verify-artifact and /usr/local/bin/verify-from-checksums"
