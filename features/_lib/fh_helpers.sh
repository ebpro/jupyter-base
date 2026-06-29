#!/usr/bin/env bash
# Shared feature helpers for version/checksum resolution and logging
# Usage: source this file from feature install scripts.

set -euo pipefail

# Logging helper
fh_log() {
  local level="${1:-info}"; shift || true
  local msg="$*"
  printf '[fh] %s: %s\n' "$level" "$msg" >&2
}

# Lookup order for versions.json files
# 1. artefacts/tool/versions.json (repo-relative)
# 2. versions.json (repo root)
# 3. /tmp/versions.json
_fh_find_versions_json() {
  local repo_root="${FH_REPO_ROOT:-/workspace}" # fallback
  local candidates=("/tmp/versions.json" "/tmp/artefacts/versions.json" "/opt/solen/artefacts/versions.json" "${repo_root}/artefacts/versions.json" "${repo_root}/versions.json")
  for p in "${candidates[@]}"; do
    if [ -f "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Internal: parse JSON for a key using python if available
_fh_json_get() {
  local file="$1"; shift
  local key="$1"; shift
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import json,sys
f=open('$file')
data=json.load(f)
f.close()
def get(d,k):
  for part in k.split('.'):
    if isinstance(d, dict) and part in d:
      d=d[part]
    else:
      return None
  return d
res=get(data,'$key')
if res is None:
  sys.exit(2)
print(res)
PY
    return $? || true
  fi
  fh_log warning "python3 not found; cannot parse $file"
  return 2
}

# Resolve version for a feature
# fh_resolve_version <feature_id> [<offline>]
fh_resolve_version() {
  local feature_id="$1"
  local offline="${2:-false}"
  local vfile
  vfile="$(_fh_find_versions_json 2>/dev/null || true)" || true
  if [ -n "$vfile" ]; then
    # try direct key match
    if command -v python3 >/dev/null 2>&1; then
      local val
      val=$(python3 - <<PY || true
import json
f=open('$vfile')
data=json.load(f)
f.close()
tools=data.get('tools',{})
print(tools.get('$feature_id') or '')
PY
)
      if [ -n "$val" ]; then
        printf '%s' "$val"
        fh_log info "version for $feature_id resolved from $vfile -> $val"
        return 0
      fi
    fi
  fi

  if [ "$offline" = "true" ] || [ "${FH_OFFLINE:-false}" = "true" ]; then
    fh_log info "offline mode: not attempting remote resolution for $feature_id"
    return 1
  fi

  # Fallback: attempt to resolve 'latest' via per-feature check_version.py if present
  if [ -f "./features/$feature_id/check_version.py" ] && command -v python3 >/dev/null 2>&1; then
    fh_log info "invoking feature hook ./features/$feature_id/check_version.py to find latest"
    local out
    out=$(python3 - <<PY || true
import runpy,sys
ns=runpy.run_path('./features/$feature_id/check_version.py')
if 'check_version' in ns and callable(ns['check_version']):
  try:
    res=ns['check_version']({}, None)
    print(res.get('latest') or res.get('version') or '')
  except Exception as e:
    sys.exit(2)
else:
  sys.exit(2)
PY
)
    if [ -n "$out" ]; then
      printf '%s' "$out"
      fh_log info "resolved latest for $feature_id via hook -> $out"
      return 0
    fi
  fi

  fh_log warning "could not resolve version for $feature_id"
  return 1
}

# Resolve checksum from checksums.json (repo root) for <name> and <version>
fh_resolve_checksum() {
  local name="$1"; local version="$2"
  local repo_root="${FH_REPO_ROOT:-/workspace}"
  local candidates=("/tmp/checksums.json" "/tmp/artefacts/checksums.json" "/opt/solen/artefacts/checksums.json" "${repo_root}/checksums.json")
  local csf=""
  for p in "${candidates[@]}"; do
    if [ -f "$p" ]; then csf="$p"; break; fi
  done
  if [ -z "$csf" ]; then
    fh_log warning "checksums.json not found in any expected location (${candidates[*]})"
    return 1
  fi
  # Prefer `jq` if available (doesn't require python in early build stages)
  if command -v jq >/dev/null 2>&1; then
    # Try canonical path: .tools[name].checksums[version]
    local ver_json
    ver_json=$(jq -c --arg n "$name" --arg v "$version" '.tools[$n].checksums[$v] // .[$n][$v] // empty' "$csf" 2>/dev/null || true)
    if [ -n "$ver_json" ] && [ "$ver_json" != "null" ]; then
      # If it's an object, extract arch-specific value
      if echo "$ver_json" | grep -q '^{'; then
        local uname_m
        uname_m=$(uname -m 2>/dev/null || echo "")
        local arch_key="${uname_m}"
        case "$uname_m" in
          x86_64|X86_64) arch_key="amd64" ;;
          aarch64|arm64) arch_key="arm64" ;;
        esac
        local val
        val=$(jq -r --arg n "$name" --arg v "$version" --arg a "$arch_key" '.tools[$n].checksums[$v][$a] // empty' "$csf" 2>/dev/null || true)
        if [ -n "$val" ] && [ "$val" != "null" ]; then
          printf '%s' "$val"
          return 0
        fi
        # try common alternate keys
        if [ "$arch_key" = "amd64" ]; then
          val=$(jq -r --arg n "$name" --arg v "$version" --arg a "x86_64" '.tools[$n].checksums[$v][$a] // empty' "$csf" 2>/dev/null || true)
        elif [ "$arch_key" = "arm64" ]; then
          val=$(jq -r --arg n "$name" --arg v "$version" --arg a "aarch64" '.tools[$n].checksums[$v][$a] // empty' "$csf" 2>/dev/null || true)
        fi
        if [ -n "$val" ] && [ "$val" != "null" ]; then
          printf '%s' "$val"
          return 0
        fi
        # If ver_json itself is a string, print it
        val=$(echo "$ver_json" | sed -n 's/^"\(.*\)"$/\1/p' || true)
        if [ -n "$val" ]; then
          printf '%s' "$val"; return 0
        fi
      else
        # ver_json is likely a plain string
        printf '%s' "$ver_json"
        return 0
      fi
    fi
  fi

  # Fallback to python (python3 preferred, then python)
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    local pycmd
    if command -v python3 >/dev/null 2>&1; then
      pycmd=python3
    else
      pycmd=python
    fi
    "$pycmd" - <<PY
import json,sys,os
f=open('$csf')
d=json.load(f)
f.close()
# Backwards compatibility: allow top-level key 'name@version'
top_key = '$name' + '@' + str('$version')
if top_key in d:
  print(d[top_key])
  sys.exit(0)
# Standard structure: tools -> name -> checksums -> version -> {arch: sha}
tools = d.get('tools', {})
tool_obj = tools.get('$name', {})
checks = tool_obj.get('checksums', {})
ver_entry = checks.get('$version') if isinstance(checks, dict) else None
if ver_entry:
  arch = os.uname().machine
  if arch in ('x86_64','X86_64'):
    arch_key = 'amd64'
  elif arch in ('aarch64','arm64'):
    arch_key = 'arm64'
  else:
    arch_key = arch
  if isinstance(ver_entry, dict):
    if arch_key in ver_entry:
      print(ver_entry[arch_key]); sys.exit(0)
    alt = 'x86_64' if arch_key == 'amd64' else ('aarch64' if arch_key == 'arm64' else None)
    if alt and alt in ver_entry:
      print(ver_entry[alt]); sys.exit(0)
  else:
    if isinstance(ver_entry, str):
      print(ver_entry); sys.exit(0)
# Also support older nested mapping: d.get(name)[version]
if isinstance(d.get('$name'), dict) and '$version' in d.get('$name'):
  v = d.get('$name')['$version']
  if isinstance(v, dict):
    arch = os.uname().machine
    if arch in ('x86_64','X86_64'):
      arch_key = 'amd64'
    elif arch in ('aarch64','arm64'):
      arch_key = 'arm64'
    else:
      arch_key = arch
    if arch_key in v:
      print(v[arch_key]); sys.exit(0)
    if 'amd64' in v:
      print(v.get('amd64')); sys.exit(0)
  else:
    print(v); sys.exit(0)
sys.exit(2)
PY
    return $? || true
  fi

  fh_log warning "no JSON parser available (jq/python); cannot parse $csf"
  return 1
}

# Write history entry (appends to generated/versions-history.json as array)
fh_write_history() {
  local entry_json="$1"
  mkdir -p generated
  local out=generated/versions-history.json
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import json,sys,os
o='$out'
e='''$entry_json'''
if os.path.exists(o):
  data=json.load(open(o))
else:
  data=[]
data.append(json.loads(e))
open(o,'w').write(json.dumps(data,indent=2))
print('written')
PY
    return 0
  fi
  # fallback: append raw line
  echo "$entry_json" >> "$out"
  return 0
}

# Convenience: resolve arch-aware asset selection
fh_resolve_arch() {
  local prefer="${FH_ARCH:-amd64}"
  echo "$prefer"
}

export -f fh_log fh_resolve_version fh_resolve_checksum fh_write_history fh_resolve_arch
