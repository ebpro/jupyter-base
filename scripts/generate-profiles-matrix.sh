#!/usr/bin/env bash
set -euo pipefail

# generate-profiles-matrix.sh
# Usage: scripts/generate-profiles-matrix.sh <matrix-file> [--prefix PREFIX]
# Example: scripts/generate-profiles-matrix.sh profiles/matrix/java-matrix.yaml --prefix 11-01-dev-java

MATRIX_FILE="${1:-}"
PREFIX="${2:-}"

if [ -z "${MATRIX_FILE}" ]; then
  echo "Usage: $0 <matrix-file> [prefix]"
  exit 2
fi

if [ ! -f "${MATRIX_FILE}" ]; then
  echo "Matrix file not found: ${MATRIX_FILE}"
  exit 2
fi

# Default prefix comes from matrix filename if not provided
if [ -z "${PREFIX}" ]; then
  PREFIX=$(basename "${MATRIX_FILE%.*}")
fi

OUT_DIR="generated/profiles"
mkdir -p "${OUT_DIR}"

# Requires yq (https://github.com/mikefarah/yq). Use Python fallback if not present.
if command -v yq >/dev/null 2>&1; then
  PARSER="yq"
else
  PARSER="python"
fi

if [ "${PARSER}" = "yq" ]; then
  entries=$(yq e '.matrix | keys' -o=json "${MATRIX_FILE}")
  keys=$(echo "${entries}" | jq -r '.[]')
  for k in ${keys}; do
    profile_name="${PREFIX}-${k}"
    options=$(yq e ".matrix.${k}.options" -o=json "${MATRIX_FILE}")
    # Build profile content
    echo "# Generated profile: ${profile_name}" > "${OUT_DIR}/${profile_name}"
    parent=$(yq e '.parent' "${MATRIX_FILE}")
    if [ "${parent}" != "null" ]; then
      echo "@parent:${parent}" >> "${OUT_DIR}/${profile_name}"
    fi
    if [ "${options}" != "null" ]; then
      # Emit options lines
      echo "" >> "${OUT_DIR}/${profile_name}"
      # convert JSON object to key=value lines
      echo "${options}" | jq -r 'to_entries | .[] | "@options: \(.key)=\(.value)"' >> "${OUT_DIR}/${profile_name}"
    fi
    echo "Wrote ${OUT_DIR}/${profile_name}"
  done
else
  # Python parser fallback
  python3 - <<'PY'
import sys, yaml, json
f=sys.argv[1]
prefix=sys.argv[2]
with open(f) as fh:
    m=yaml.safe_load(f)
parent=m.get('parent')
mat=m.get('matrix',{})
for k,v in mat.items():
    name=f"{prefix}-{k}"
    out=f"generated/profiles/{name}"
    with open(out,'w') as ofh:
        ofh.write(f"# Generated profile: {name}\n\n")
        if parent:
            ofh.write(f"@parent:{parent}\n\n")
        opts=v.get('options',{})
        for ok,ov in opts.items():
            ofh.write(f"@options: {ok}={ov}\n")
    print('Wrote',out)
PY
fi

echo "Done. Generated profiles are in ${OUT_DIR}/"
