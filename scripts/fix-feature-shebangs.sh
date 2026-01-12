#!/usr/bin/env bash
set -euo pipefail

# fix-feature-shebangs.sh
# Ensure each feature `install.sh` begins with a shebang on the first line.
# If a shebang exists elsewhere in the file (common after injector), move it to the top.

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
DRY_RUN=true
while [[ ${1:-} != "" ]]; do
  case "$1" in
    --apply) DRY_RUN=false; shift ;;
    --help) echo "Usage: $0 [--apply]"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "Scanning features for install.sh shebang placement (dry-run=$DRY_RUN)"
for f in "$ROOT"/features/*/install.sh; do
  [ -f "$f" ] || continue
  first=$(sed -n '1p' "$f" || echo "")
  if [[ "$first" =~ ^#! ]]; then
    echo "OK: $f (shebang at top)"
    continue
  fi
  # find first shebang line index
  lineno=$(nl -ba "$f" | awk '/^ *[0-9]+\t#!/{print $1; exit}' || true)
  if [ -z "$lineno" ]; then
    echo "NO_SHEBANG: $f";
    continue
  fi
  echo "SHEBANG_ELSEWHERE: $f (line $lineno)"
  if [ "$DRY_RUN" = false ]; then
    tmp=$(mktemp)
    shebang=$(sed -n "${lineno}p" "$f")
    # remove that line and write new file with shebang at top
    awk -v ln="$lineno" 'NR==ln{next} {print}' "$f" > "$tmp"
    printf "%s\n" "$shebang" > "$f.tmp"
    cat "$tmp" >> "$f.tmp"
    mv "$f.tmp" "$f"
    rm -f "$tmp"
    echo "  -> patched $f (shebang moved to top)"
  else
    echo "  -> would move shebang to top (run with --apply to modify)"
  fi
done

echo "Done"
exit 0
