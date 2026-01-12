#!/usr/bin/env bash
set -euo pipefail

cat > /usr/local/bin/toolcache-get <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Usage: toolcache-get <name> <version> <url> [sha256] [extract_path]
name=$1
ver=$2
url=$3
sha=${4:-}
extract_path=${5:-}
prefix="/opt/toolcache/${name}/${ver}"
bin_dir="${prefix}/bin"

if [ -d "${prefix}" ] && [ -n "$(ls -A "${prefix}" 2>/dev/null || true)" ]; then
  echo "${prefix}"
  echo "toolcache-get: cache hit ${name} ${ver} -> ${prefix}" >&2
  exit 0
else
  echo "toolcache-get: cache miss ${name} ${ver}" >&2
fi

mkdir -p "${prefix}"
tmpfile=$(mktemp -p /tmp "${name}-${ver}.XXXX")

download_with_backoff() {
  local _url="$1" _dest="$2"
  local max_attempts=6
  local attempt=0
  local backoff=2
  local headers

  # Supply GitHub token if present to reduce rate-limiting
  local auth_header
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header=( -H "Authorization: Bearer ${GITHUB_TOKEN}" )
  else
    auth_header=()
  fi

  while [ $attempt -lt $max_attempts ]; do
    attempt=$((attempt+1))
    rm -f "$_dest" || true
    headers=$(mktemp)
    if curl -sS -L -D "$headers" "${auth_header[@]}" -o "$_dest" --connect-timeout 15 --max-time 300 "$_url"; then
      status=$(awk 'END{for(i=NR;i>0;i--){ if($0 ~ /^HTTP/){print $2; exit}}}' "$headers") || status=200
      [ -z "$status" ] && status=200
    else
      status=$(awk 'END{for(i=NR;i>0;i--){ if($0 ~ /^HTTP/){print $2; exit}}}' "$headers") || status=0
    fi

    if [ "$status" -ge 200 ] && [ "$status" -lt 300 ] && [ -s "$_dest" ]; then
      rm -f "$headers" || true
      return 0
    fi

    if [ "$status" -eq 429 ] || [ "$status" -eq 403 ]; then
      retry_after=$(awk '/^Retry-After:/ {print $2}' "$headers" | tr -d '\r' || true)
      if [ -z "$retry_after" ]; then
        reset=$(awk -F: '/^X-RateLimit-Reset/ {print $2}' "$headers" | tr -d ' \r' || true)
        if [ -n "$reset" ]; then
          now=$(date +%s)
          wait_for=$(( reset - now ))
          [ $wait_for -lt 0 ] && wait_for=10
          retry_after=$wait_for
        fi
      fi
      if [ -n "$retry_after" ]; then
        sleep $retry_after
        rm -f "$headers" || true
        continue
      fi
    fi

    sleep $backoff
    backoff=$((backoff * 2))
    rm -f "$headers" || true
  done

  return 1
}

if ! download_with_backoff "${url}" "${tmpfile}"; then
  echo "toolcache-get: failed to download ${url}" >&2
  rm -f "${tmpfile}" || true
  exit 1
fi

if [ -n "${sha}" ]; then
  if command -v fh_verify_from_checksums >/dev/null 2>&1; then
    # Try to infer an arch token from the URL to lookup checksums.json entries
    infer_arch_from_url() {
      local u="$1"
      local a=""
      if [[ "$u" =~ linux[_-](amd64|x86_64) ]]; then a="${BASH_REMATCH[1]}"; fi
      if [[ -z "$a" && "$u" =~ linux[_-](arm64|aarch64) ]]; then a="${BASH_REMATCH[1]}"; fi
      if [[ -z "$a" && "$u" =~ _([a-zA-Z0-9_]+)\.tar\.gz ]]; then a="${BASH_REMATCH[1]}"; fi
      case "$a" in
        x86_64) echo "amd64" ;;
        amd64) echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64) echo "arm64" ;;
        *) echo "" ;;
      esac
    }

    cand_arch=$(infer_arch_from_url "${url}") || cand_arch=""
    if [ -n "${cand_arch}" ]; then
      if ! fh_verify_from_checksums "${name}" "${ver}" "${cand_arch}" "${tmpfile}"; then
        # fall back to verify-artifact or sha256sum if centralized verification fails
        if command -v verify-artifact >/dev/null 2>&1; then
          verify-artifact "${sha}" "${tmpfile}"
        else
          echo "${sha}  ${tmpfile}" > "${tmpfile}.sha256"
          sha256sum -c "${tmpfile}.sha256"
          rm -f "${tmpfile}.sha256"
        fi
      fi
    else
      # Couldn't infer arch; fall back to existing verification strategy
      if command -v verify-artifact >/dev/null 2>&1; then
        verify-artifact "${sha}" "${tmpfile}"
      else
        echo "${sha}  ${tmpfile}" > "${tmpfile}.sha256"
        sha256sum -c "${tmpfile}.sha256"
        rm -f "${tmpfile}.sha256"
      fi
    fi
  else
    if command -v verify-artifact >/dev/null 2>&1; then
      verify-artifact "${sha}" "${tmpfile}"
    else
      echo "${sha}  ${tmpfile}" > "${tmpfile}.sha256"
      sha256sum -c "${tmpfile}.sha256"
      rm -f "${tmpfile}.sha256"
    fi
  fi
fi

case "${url}" in
  *.tar.gz|*.tgz)
    if [ -n "${extract_path}" ]; then
      mkdir -p "${prefix}"
      tar -xzf "${tmpfile}" -C "${prefix}" "${extract_path}" || true
      # if extracted single file, move it to bin
      if [ -f "${prefix}/${extract_path}" ]; then
        mkdir -p "${bin_dir}"
        mv "${prefix}/${extract_path}" "${bin_dir}/"
        chmod +x "${bin_dir}/"* || true
      fi
    else
      mkdir -p "${prefix}"
      tar -xzf "${tmpfile}" -C "${prefix}"
    fi
    ;;
  *)
    mkdir -p "${bin_dir}"
    mv "${tmpfile}" "${bin_dir}/$(basename "${url}")"
    chmod +x "${bin_dir}/"* || true
    tmpfile=""
    ;;
esac

rm -f "${tmpfile}" || true
echo "toolcache-get: cached ${name} ${ver} -> ${prefix}" >&2
echo "${prefix}"
EOF

chmod +x /usr/local/bin/toolcache-get || true

echo "toolcache: installed /usr/local/bin/toolcache-get"
