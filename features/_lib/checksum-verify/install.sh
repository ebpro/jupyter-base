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
# checksums.json at the repository root (devcontainer/build context).
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

# Prefer /tmp/checksums.json (used during image builds), fallback to repo-root checksums.json
if [ -f /tmp/checksums.json ]; then
  checksums=/tmp/checksums.json
elif [ -f checksums.json ]; then
  checksums=checksums.json
else
  echo "No checksums.json found at /tmp/checksums.json or checksums.json" >&2
  exit 3
fi

sha=""
# Prefer fh_resolve_checksum when available (runtime helper), fallback to checksums.json
if ! command -v fh_resolve_checksum >/dev/null 2>&1; then
  echo "verify-from-checksums: fh_resolve_checksum not available; checksum resolution required" >&2
  exit 4
fi
sha=$(fh_resolve_checksum "$tool" "$ver" || true)
if [ -z "$sha" ]; then
  echo "Checksum not found for ${tool} ${ver} ${arch} via fh_resolve_checksum" >&2
  exit 4
fi

verify-artifact "$sha" "$file"
exit $?
EOF

chmod +x /usr/local/bin/verify-from-checksums || true

echo "checksum-verify: installed /usr/local/bin/verify-artifact and /usr/local/bin/verify-from-checksums"
