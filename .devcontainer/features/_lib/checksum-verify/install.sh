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

echo "checksum-verify: installed /usr/local/bin/verify-artifact"
