#!/usr/bin/env bash
set -euo pipefail

# stage-toolcache.sh — seed and consume the Harbor toolcache mirror
# (solen/toolcache/<tool>-<arch>).
#
# WHY. A live get.helm.sh download has never succeeded on the self-hosted ARC
# runners (PMTU blackhole or an Azure-Front-Door fault — unsettled, and this
# design must not depend on which it is). features/ is in the install-RUN
# cache key, so any feature-script change forces a cold fetch. The mirror buys
# immunity to origin-hosted failure of any cause: build legs fetch
# publisher-digest-pinned archives from Harbor, stage them under
# artefacts/toolcache/, and the generated Dockerfile's seed RUN primes the
# shared /opt/toolcache BuildKit volume from that tree, so download_direct
# cache-hits instead of touching the failing origin.
#
# INTEGRITY RULE (binding). A mirror must NEVER supply its own digest. Every
# digest used to construct a blob URL is read from the IN-REPO checksums.json,
# which is PR-reviewed and publisher-attested. Never read a digest from any
# Harbor tag, annotation or manifest — and never fetch by tag: fetching
#   GET /v2/solen/toolcache/<tool>-<arch>/blobs/sha256:<digest>
# embeds the expected content IN THE URL WE REQUEST, so the mirror cannot
# substitute bytes without changing that URL (deliberate hardening over a
# tag-based fetch, which would reintroduce a verify-before-use race). The
# sha256 re-check after fetch is belt-and-braces against local corruption.
# The sha256-<digest> tag on each object exists for BROWSING ONLY.
#
# OBJECT LAYOUT (whole-archive). One OCI object per archive, repository
# solen/toolcache/<tool>-<arch>, layer = the UNEXTRACTED upstream archive. Its
# blob digest therefore equals the publisher digest and the object is
# byte-identical to the /opt/toolcache entry download_direct expects. We push
# archives, never /opt/toolcache contents.
#
# STAGING LAYOUT matches the only reader — download_direct
# (features/_lib/download-release/install.sh:727):
#   $TOOLCACHE_DIR/$tool/$(basename "$url")   — no version, no arch.
# tool_url() replicates the URL construction of the six frozen download_direct
# call sites exactly: kubernetes-client/install.sh:78,94,105,
# kubernetes-dev/install.sh:81, tilt/install.sh:63, texlive/install.sh:91-96.
# If a call site ever changes, this table must change with it (verified by
# the mapping assertion in the ci-publish staging step's own dry-run tooling).
# The TOOLS list is deliberately ONLY these six tools' archives; other origins
# (nodejs.org, starship.rs, tlnet.yihui.org, get.docker.com, get.volta.sh,
# get.sdkman.io, Homebrew, apt.postgresql.org) are a ratified follow-up batch,
# not an oversight.
#
# CREDENTIALS. solen is a PRIVATE Harbor project: pull AND push both require
# the robot credential (HARBOR_USERNAME / HARBOR_ROBOT_SECRET — names
# documented in .env.example; none provisioned yet, creating one is an
# operator decision). Absence is a clean skip, never a failure: pull exits 0
# with a skip message so each leg behaves exactly as before the mirror.
#
# TOOLING. curl only — no oras, no skopeo, no docker, and no solen invocation
# (solen lives in a host venv at /usr/local/lib/python3.12/dist-packages/solen
# and must never be called from image-side logic). Harbor answers the token
# exchange at the realm measured from its 401 challenge
# (realm=https://harbor.ebruno.fr/service/token, service=harbor-registry).
# Secrets are passed via curl -u on ephemeral CI runners only and are NEVER
# echoed, logged or written to disk; tokens are held in shell variables.
#
# MODES.
#   --mode list   print the derived matrix (TSV: tool arch version digest url staged-path)
#   --mode pull   fetch each object's blob BY DIGEST and stage it; best-effort,
#                 always exits 0 so a build leg degrades to upstream downloads
#   --mode push   fetch each archive from upstream, verify the publisher
#                 digest, and push missing OCI objects to Harbor; idempotent
#                 (content-addressed — objects already present are skipped)
#
# USAGE.
#   scripts/stage-toolcache.sh --mode list [--arch amd64[,...]]
#   scripts/stage-toolcache.sh --mode pull --arch "$ARCH" --out artefacts/toolcache
#   scripts/stage-toolcache.sh --mode push --arch amd64,arm64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$ROOT_DIR/versions.json}"
CHECKSUMS_FILE="${CHECKSUMS_FILE:-$ROOT_DIR/checksums.json}"

HARBOR_BASE="${HARBOR_BASE_URL:-https://harbor.ebruno.fr}"
TOKEN_SERVICE="harbor-registry"   # from the measured 401 Bearer challenge
REPO_PREFIX="solen/toolcache"

TOOLS=(kubectl helm kustomize k9s tilt tinytex)

MODE=""
ARCHES="amd64,arm64"
OUT="artefacts/toolcache"

usage() { sed -n '/^# MODES\./,/^# USAGE\./p;/^#   scripts/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)    MODE="${2:-}"; shift 2 ;;
    --arch)    ARCHES="${2:-}"; shift 2 ;;
    --out)     OUT="${2:-}"; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 2 ;;
  esac
done

case "$MODE" in list|pull|push) ;; *) echo "ERROR: --mode must be list|pull|push" >&2; usage 2 ;; esac

warn() { echo "   ⚠️  $*" >&2; }
note() { echo "   $*"; }
err()  { echo "   ❌ $*" >&2; }

# Portable sha256 (linux: sha256sum; macOS dev shell: shasum -a 256).
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# Matrix derivation: version from versions.json (SoT), digest from IN-REPO
# checksums.json (never from Harbor — see INTEGRITY RULE). Checksum key strips
# one leading "v" exactly like _dr_version_key() in download-release.
# ---------------------------------------------------------------------------

# URL construction replicated per call site. Returns the URL download_direct
# would build for tool@arch; basename "$(url)" is the toolcache leaf name.
tool_url() {
  local tool="$1" ver="$2" arch="$3" tag nov ta
  case "$tool" in
    kubectl)   # kubernetes-client/install.sh:78 (literal 'v' prefix)
      printf 'https://dl.k8s.io/release/v%s/bin/linux/%s/kubectl' "$ver" "$arch" ;;
    helm)      # kubernetes-client/install.sh:94 (tag keeps/gets leading v)
      tag="$ver"; case "$tag" in v*) : ;; *) tag="v$tag" ;; esac
      printf 'https://get.helm.sh/helm-%s-linux-%s.tar.gz' "$tag" "$arch" ;;
    kustomize) # kubernetes-client/install.sh:105 (leading v stripped, %2F-encoded tag)
      nov="${ver#v}"
      printf 'https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%%2Fv%s/kustomize_v%s_linux_%s.tar.gz' "$nov" "$nov" "$arch" ;;
    k9s)       # kubernetes-dev/install.sh:81 (tag keeps/gets leading v)
      tag="$ver"; case "$tag" in v*) : ;; *) tag="v$tag" ;; esac
      printf 'https://github.com/derailed/k9s/releases/download/%s/k9s_Linux_%s.tar.gz' "$tag" "$arch" ;;
    tilt)      # tilt/install.sh:63 (leading v stripped; amd64->x86_64 naming)
      nov="${ver#v}"; ta="$arch"
      case "$arch" in
        amd64|x86_64|X86_64) ta="x86_64" ;;
        arm64|aarch64)       ta="arm64" ;;
        *)                   ta="x86_64" ;;
      esac
      printf 'https://github.com/tilt-dev/tilt/releases/download/v%s/tilt.%s.linux.%s.tar.gz' "$nov" "$nov" "$ta" ;;
    tinytex)   # texlive/install.sh:91-96 (INSTALLER=installer-unix; same asset every arch)
      printf 'https://github.com/rstudio/tinytex-releases/releases/download/v%s/installer-unix-v%s.tar.gz' "$ver" "$ver" ;;
    *) return 1 ;;
  esac
}

# Emits one TSV row per (tool, arch) with a resolvable digest:
# tool<TAB>arch<TAB>version<TAB>digest<TAB>url<TAB>staged-path
matrix() {
  local arch tool ver key digest url base
  for arch in "${ARCH_LIST[@]}"; do
    for tool in "${TOOLS[@]}"; do
      ver="$(jq -r --arg t "$tool" '.tools[$t] // empty' "$VERSIONS_FILE")"
      if [ -z "$ver" ]; then warn "$tool: no version in $VERSIONS_FILE; skipping"; continue; fi
      key="${ver#v}"
      digest="$(jq -r --arg t "$tool" --arg k "$key" --arg a "$arch" \
        '.tools[$t].checksums[$k][$a] // empty' "$CHECKSUMS_FILE")"
      if [ -z "$digest" ]; then warn "$tool@$key: no $arch digest in $CHECKSUMS_FILE; skipping"; continue; fi
      url="$(tool_url "$tool" "$ver" "$arch")" || { warn "$tool: unknown tool"; continue; }
      base="${url##*/}"
      printf '%s\t%s\t%s\t%s\t%s\t%s/%s/%s\n' "$tool" "$arch" "$ver" "$digest" "$url" "$OUT" "$tool" "$base"
    done
  done
}

# ---------------------------------------------------------------------------
# Harbor Bearer exchange (curl only). Registry auth is NOT basic: the token
# endpoint takes basic auth and returns a scoped bearer token that the blob /
# manifest endpoints then require. The secret is never echoed.
# ---------------------------------------------------------------------------
harbor_token() {
  local scope="$1"
  curl -fsSL --get "$HARBOR_BASE/service/token" \
    -u "${HARBOR_USERNAME}:${HARBOR_ROBOT_SECRET}" \
    --data-urlencode "service=$TOKEN_SERVICE" \
    --data-urlencode "scope=$scope" \
    | jq -r '.token // empty'
}

require_credentials() {
  # 0 = present, 1 = absent (caller decides skip semantics; both modes treat
  # absence as a clean skip so this never fails a leg).
  if [ -z "${HARBOR_USERNAME:-}" ] || [ -z "${HARBOR_ROBOT_SECRET:-}" ]; then
    echo "Toolcache mirror credentials are not configured (HARBOR_USERNAME/HARBOR_ROBOT_SECRET unset)."
    echo "PULL AND PUSH BOTH REQUIRE CREDENTIALS: solen is a private Harbor project (anonymous pull measured 401 with an empty-scope token). Skipping — behaviour is identical to before the mirror existed."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# PULL: fetch blobs by digest, verify, stage. Best-effort: every failure path
# warns and continues; the mode ALWAYS exits 0 so the build leg proceeds (the
# install RUN then just re-downloads from upstream, i.e. today's behaviour).
# ---------------------------------------------------------------------------
mode_pull() {
  local tool arch ver digest url staged tmp actual got
  while IFS=$'\t' read -r tool arch ver digest url staged; do
    [ -n "${staged:-}" ] || continue
    if [ -f "$staged" ]; then note "already staged: $staged"; continue; fi
    tmp="$(mktemp)"
    local repo="$REPO_PREFIX/$tool-$arch"
    local tok
    tok="$(harbor_token "repository:$repo:pull" || true)"
    if [ -z "$tok" ]; then
      warn "$repo: token exchange failed (bad credential scope?); falling back to upstream for this entry"
      rm -f "$tmp"; continue
    fi
    # BY DIGEST, never by tag — see INTEGRITY RULE.
    got="$(curl -sS -o "$tmp" -w '%{http_code}' -m 120 \
      -H "Authorization: Bearer $tok" \
      "$HARBOR_BASE/v2/$repo/blobs/sha256:$digest" 2>/dev/null || echo 000)"
    if [ "$got" != "200" ]; then
      warn "$repo blob sha256:${digest:0:12}… -> HTTP $got (object absent or denied); upstream download will be used for $tool/$arch"
      rm -f "$tmp"; continue
    fi
    actual="$(_sha256 "$tmp")"
    if [ "$actual" != "$digest" ]; then
      err "$repo blob digest MISMATCH (expected $digest got $actual) — refusing to stage; upstream download will be used"
      rm -f "$tmp"; continue
    fi
    mkdir -p "$(dirname "$staged")"
    mv "$tmp" "$staged"; chmod 0644 "$staged"
    note "staged $staged (sha256:$digest, digest-pinned fetch)"
  done < <(matrix)
  # Staging is advisory: never a build-leg failure, whatever happened above.
  return 0
}

# ---------------------------------------------------------------------------
# PUSH: one OCI object per archive (config blob + archive layer + manifest
# tagged sha256-<digest> for browsing). Content-addressed and idempotent:
# objects already published are skipped. Exits 1 if any entry failed, so the
# advisory CI job can annotate it (the job itself stays green by design).
# ---------------------------------------------------------------------------
push_blob() { # repo token file digest
  local repo="$1" tok="$2" file="$3" digest="$4" loc sep
  loc="$(curl -fsSL -X POST -D - -o /dev/null \
    -H "Authorization: Bearer $tok" \
    -H 'Content-Type: application/octet-stream' \
    "$HARBOR_BASE/v2/$repo/blobs/uploads/" | tr -d '\r' \
    | awk 'tolower($1)=="location:"{print $2}')"
  [ -n "$loc" ] || { err "$repo: no upload location from POST /blobs/uploads/"; return 1; }
  case "$loc" in
    http*) : ;;
    /*)    loc="$HARBOR_BASE$loc" ;;
    *)     loc="$HARBOR_BASE/$loc" ;;
  esac
  sep='?'; case "$loc" in *\?*) sep='&' ;; esac
  curl -fsSL -X PUT --data-binary "@$file" \
    -H "Authorization: Bearer $tok" \
    "${loc}${sep}digest=${digest}" >/dev/null
}

mode_push() {
  local tool arch ver digest url tmp actual fail=0
  while IFS=$'\t' read -r tool arch ver digest url _staged; do
    [ -n "${url:-}" ] || continue
    local repo="$REPO_PREFIX/$tool-$arch"
    local tok
    tok="$(harbor_token "repository:$repo:push,pull" || true)"
    if [ -z "$tok" ]; then
      err "$repo: token exchange failed (check robot push scope)"; fail=1; continue
    fi
    # Idempotence: HEAD the browsing tag's manifest. This READS a tag for an
    # existence check ONLY — the digest compared/stored is checksums.json's,
    # never anything Harbor supplied.
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -I \
      -H "Authorization: Bearer $tok" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      "$HARBOR_BASE/v2/$repo/manifests/sha256-$digest" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then note "$repo sha256:${digest:0:12}… already published; skipping"; continue; fi
    note "publishing $repo <- $url"
    tmp="$(mktemp)"
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 600 -o "$tmp" "$url"; then
      err "$repo: upstream fetch failed ($url) — the very origin flakiness the mirror exists to absorb; retry on the next checksums.json change"
      rm -f "$tmp"; fail=1; continue
    fi
    actual="$(_sha256 "$tmp")"
    if [ "$actual" != "$digest" ]; then
      err "$repo: upstream archive does NOT match the in-repo publisher digest (got $actual) — refusing to mirror wrong bytes"
      rm -f "$tmp"; fail=1; continue
    fi
    local cfg cfgd cfgs layd man
    cfg="$(mktemp)"; printf '{}' > "$cfg"
    cfgd="sha256:$(_sha256 "$cfg")"; cfgs="$(wc -c < "$cfg" | tr -d ' ')"
    layd="sha256:$digest"; local laysz; laysz="$(wc -c < "$tmp" | tr -d ' ')"
    if ! push_blob "$repo" "$tok" "$cfg" "$cfgd"; then err "$repo: config blob push failed"; rm -f "$tmp" "$cfg"; fail=1; continue; fi
    if ! push_blob "$repo" "$tok" "$tmp" "$layd"; then err "$repo: archive blob push failed"; rm -f "$tmp" "$cfg"; fail=1; continue; fi
    man="$(mktemp)"
    jq -n --arg cd "$cfgd" --argjson cs "$cfgs" --arg ld "$layd" --argjson ls "$laysz" '{
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      config:  { mediaType: "application/vnd.oci.image.config.v1+json", digest: $cd, size: $cs },
      layers: [ { mediaType: "application/vnd.oci.image.layer.v1.tar", digest: $ld, size: $ls } ]
    }' > "$man"
    # The tag is sha256-<digest> for BROWSING ONLY; consumers fetch the blob
    # by digest and never resolve a tag.
    if ! curl -fsSL -X PUT --data-binary "@$man" \
        -H "Authorization: Bearer $tok" \
        -H 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
        "$HARBOR_BASE/v2/$repo/manifests/sha256-$digest" >/dev/null; then
      err "$repo: manifest push failed"; rm -f "$tmp" "$cfg" "$man"; fail=1; continue
    fi
    rm -f "$tmp" "$cfg" "$man"
    note "pushed $repo (tag sha256-$digest, layer = unextracted archive)"
  done < <(matrix)
  return "$fail"
}

# ---------------------------------------------------------------------------
main() {
  local c missing=0
  for c in curl jq; do
    command -v "$c" >/dev/null 2>&1 || { err "$c is required but not installed"; missing=1; }
  done
  if [ "$missing" = 1 ]; then
    # Advisory by role: pull must never fail a leg; list/push are host-side
    # tools where a hard error is correct.
    if [ "$MODE" = "pull" ]; then warn "missing dependencies; skipping staging"; exit 0; fi
    exit 2
  fi
  [ -f "$VERSIONS_FILE" ] && [ -f "$CHECKSUMS_FILE" ] || {
    if [ "$MODE" = "pull" ]; then warn "versions.json/checksums.json not found; skipping staging"; exit 0; fi
    echo "ERROR: $VERSIONS_FILE and $CHECKSUMS_FILE are required" >&2; exit 2
  }

  IFS=',' read -r -a ARCH_LIST <<< "$ARCHES"
  local a ok=0
  for a in "${ARCH_LIST[@]}"; do case "$a" in amd64|arm64) ok=1 ;; *) ;; esac; done
  if [ "$ok" != 1 ]; then
    if [ "$MODE" = "pull" ]; then warn "no supported arch in '$ARCHES'; skipping"; exit 0; fi
    echo "ERROR: --arch must include amd64 and/or arm64 (got '$ARCHES')" >&2; exit 2
  fi

  case "$MODE" in
    list)
      printf 'tool\tarch\tversion\tdigest\turl\tstaged-path\n'
      matrix
      ;;
    pull)
      require_credentials || exit 0
      mode_pull
      ;;
    push)
      require_credentials || exit 0
      mode_push
      ;;
  esac
}
main
