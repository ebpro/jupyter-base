#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-Artefacts}"

if ! command -v jq >/dev/null 2>&1; then
  echo "validate-artefacts: jq is required for validation" >&2
  exit 2
fi

echo "validate-artefacts: validating JSON syntax"
jq -e . "${ROOT}/versions.json" >/dev/null
jq -e . "${ROOT}/checksums.json" >/dev/null

# Optional metadata file controls which tools require checksums
METADATA_FILE="${ROOT}/tool-metadata.json"
if [ -f "${METADATA_FILE}" ]; then
  echo "validate-artefacts: using metadata ${METADATA_FILE}"
  jq -e . "${METADATA_FILE}" >/dev/null || { echo "ERROR: invalid JSON in ${METADATA_FILE}" >&2; exit 2; }
else
  echo "validate-artefacts: metadata ${METADATA_FILE} not found — falling back to defaults"
fi

echo "validate-artefacts: checking tools have checksums (respecting metadata)"
missing=0
# Default exceptions when no metadata is available (tools installed via package manager / not requiring checksums)
DEFAULT_EXCEPTIONS=(buildx compose docker scout tinytex)

for tool in $(jq -r '.tools | keys[]' "${ROOT}/versions.json"); do
  ver=$(jq -r --arg t "$tool" '.tools[$t]' "${ROOT}/versions.json")
  if [ "$ver" = "" ] || [ "$ver" = "null" ]; then
    echo "WARN: tool '$tool' has empty version in ${ROOT}/versions.json"
    missing=1
    continue
  fi

  # Determine whether checksum validation is required for this tool
  require_checksum=""
  if [ -f "${METADATA_FILE}" ]; then
    require_checksum=$(jq -r --arg t "$tool" '.tools[$t].require_checksum // empty' "${METADATA_FILE}" 2>/dev/null || true)
  fi

  if [ -z "${require_checksum}" ]; then
    # No metadata entry — use default exceptions
    skip=0
    for ex in "${DEFAULT_EXCEPTIONS[@]}"; do
      if [ "$ex" = "$tool" ]; then
        skip=1
        break
      fi
    done
    if [ $skip -eq 1 ]; then
      echo "INFO: skipping checksum check for $tool (default exception)"
      continue
    fi
  else
    # explicit metadata value: treat 'false' (case-insensitive) as skip
    case "${require_checksum}" in
      false|False|"0")
        echo "INFO: skipping checksum check for $tool (metadata)"
        continue
        ;;
      true|True|"1")
        ;; # proceed to check
      *)
        ;; # unknown -> proceed to check
    esac
  fi

  ok=$(jq -r --arg t "$tool" --arg v "$ver" '.tools[$t].checksums[$v] // empty' "${ROOT}/checksums.json" 2>/dev/null || true)
  if [ -z "$ok" ]; then
    echo "WARN: checksum missing for $tool@$ver in ${ROOT}/checksums.json"
    missing=1
  fi
done

if [ $missing -ne 0 ]; then
  echo "validate-artefacts: validation failed (missing items)" >&2
  exit 3
fi

echo "validate-artefacts: OK"
