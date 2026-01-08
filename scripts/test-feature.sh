#!/usr/bin/env bash
set -euo pipefail

# Feature Testing Script
# Tests individual features in isolated containers
# Usage: ./scripts/test-feature.sh FEATURE_ID [--build-first] [--verbose]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FEATURES_DIR="$ROOT_DIR/.devcontainer/features"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC}  $1"; }
log_info() { echo -e "${BLUE}→${NC} $1"; }

# Parse arguments
FEATURE_ID=""
BUILD_FIRST=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --build-first)
      BUILD_FIRST=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      cat <<EOF
Usage: $0 FEATURE_ID [OPTIONS]

Test a single feature in an isolated container.

Arguments:
  FEATURE_ID          Feature to test (e.g., node, python-conda, gh-cli)

Options:
  --build-first       Build test image before running tests
  --verbose, -v       Show detailed output
  --help, -h          Show this help message

Examples:
  # Test node feature
  $0 node

  # Build and test postgresql-client
  $0 postgresql-client --build-first

  # Test with verbose output
  $0 kubernetes-client --verbose

EOF
      exit 0
      ;;
    *)
      if [ -z "$FEATURE_ID" ]; then
        FEATURE_ID="$1"
      else
        echo "Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$FEATURE_ID" ]; then
  echo "Error: FEATURE_ID required" >&2
  echo "Usage: $0 FEATURE_ID [--build-first] [--verbose]" >&2
  exit 1
fi

FEATURE_PATH="$FEATURES_DIR/$FEATURE_ID"
FEATURE_JSON="$FEATURE_PATH/feature.json"

# Validate feature exists
if [ ! -d "$FEATURE_PATH" ]; then
  log_fail "Feature directory not found: $FEATURE_PATH"
  exit 1
fi

if [ ! -f "$FEATURE_JSON" ]; then
  log_fail "feature.json not found: $FEATURE_JSON"
  exit 1
fi

echo "===================================================================="
echo "Feature Testing: $FEATURE_ID"
echo "===================================================================="
echo

# Load feature metadata
FEATURE_NAME=$(jq -r '.name // .id' "$FEATURE_JSON")
FEATURE_VERSION=$(jq -r '.version // "unknown"' "$FEATURE_JSON")
DEPENDS_ON=$(jq -r '.dependsOn[]? // empty' "$FEATURE_JSON" | tr '\n' ' ')
PROVIDES=$(jq -r '.provides[]? // empty' "$FEATURE_JSON" | tr '\n' ' ')
POST_INSTALL_CMD=$(jq -r '.postInstallCheck.command // empty' "$FEATURE_JSON")
PLATFORMS=$(jq -r '.platforms[]? // empty' "$FEATURE_JSON" | tr '\n' ' ')

log_info "Name: $FEATURE_NAME"
log_info "Version: $FEATURE_VERSION"
[ -n "$DEPENDS_ON" ] && log_info "Dependencies: $DEPENDS_ON"
[ -n "$PROVIDES" ] && log_info "Provides: $PROVIDES"
[ -n "$PLATFORMS" ] && log_info "Platforms: $PLATFORMS"
echo

# Build test image
TEST_IMAGE="feature-test-${FEATURE_ID}:latest"
TEST_DOCKERFILE="$ROOT_DIR/.test-dockerfile-${FEATURE_ID}"

if [ "$BUILD_FIRST" = true ]; then
  log_info "Building test image..."
  
  # Generate minimal Dockerfile for testing this feature
  cat > "$TEST_DOCKERFILE" <<EOF
ARG VARIANT="ubuntu-24.04"
FROM mcr.microsoft.com/devcontainers/base:\${VARIANT}

# Set up user
ARG NB_USER=jovyan
ARG NB_UID=1001
ARG NB_GID=1001
ENV HOME=/home/jovyan
WORKDIR /home/jovyan

# Copy shared helpers
COPY shared/_lib/helpers.sh /opt/solen/_lib/helpers.sh
COPY Artefacts /opt/solen/Artefacts
ENV FEATURE_HELPERS_DIR=/opt/solen/_lib ARTIFACTS_DIR=/opt/solen/Artefacts

# Initialize feature helpers
RUN mkdir -p /opt/.features /scripts && \\
    printf "source /opt/solen/_lib/helpers.sh || true" > /scripts/feature_helpers.sh

# Install dependencies first
EOF

  # Add dependency installations
  if [ -n "$DEPENDS_ON" ]; then
    for dep in $DEPENDS_ON; do
      if [ -f "$FEATURES_DIR/$dep/install.sh" ]; then
        cat >> "$TEST_DOCKERFILE" <<EOF
COPY .devcontainer/features/$dep /tmp/features/$dep
RUN chmod +x /tmp/features/$dep/install.sh && \\
    bash /tmp/features/$dep/install.sh || true
EOF
      fi
    done
  fi

  # Install the feature being tested
  cat >> "$TEST_DOCKERFILE" <<EOF

# Install feature under test
COPY .devcontainer/features/$FEATURE_ID /tmp/features/$FEATURE_ID
COPY Artefacts /tmp/Artefacts
COPY scripts /tmp/scripts

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \\
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \\
    --mount=type=cache,target=/opt/toolcache,sharing=locked \\
    --mount=type=cache,target=/root/.cache,sharing=locked \\
    chmod +x /tmp/features/$FEATURE_ID/install.sh && \\
    bash /tmp/features/$FEATURE_ID/install.sh

USER \${NB_USER}
WORKDIR /home/jovyan
EOF

  # Build with BuildKit
  export DOCKER_BUILDKIT=1
  if [ "$VERBOSE" = true ]; then
    docker build -f "$TEST_DOCKERFILE" -t "$TEST_IMAGE" "$ROOT_DIR"
  else
    docker build -f "$TEST_DOCKERFILE" -t "$TEST_IMAGE" "$ROOT_DIR" > /dev/null 2>&1
  fi
  
  if [ $? -eq 0 ]; then
    log_pass "Test image built successfully"
  else
    log_fail "Failed to build test image"
    rm -f "$TEST_DOCKERFILE"
    exit 1
  fi
  
  rm -f "$TEST_DOCKERFILE"
  echo
fi

# Check if test image exists
if ! docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
  log_fail "Test image not found: $TEST_IMAGE"
  log_info "Use --build-first to build the test image"
  exit 1
fi

# Run tests
echo "===================================================================="
echo "Running Tests"
echo "===================================================================="
echo

TESTS_PASSED=0
TESTS_FAILED=0

# Helper to run test in container
run_test() {
  local test_name="$1"
  local test_cmd="$2"
  local user="${3:-jovyan}"
  
  log_info "Test: $test_name"
  
  local output
  if output=$(docker run --rm -u "$user" "$TEST_IMAGE" bash -c "$test_cmd" 2>&1); then
    log_pass "$test_name"
    ((TESTS_PASSED++)) || true
    [ "$VERBOSE" = true ] && echo "  Output: $output"
    return 0
  else
    log_fail "$test_name"
    ((TESTS_FAILED++)) || true
    [ "$VERBOSE" = true ] && echo "  Error: $output"
    return 1
  fi
}

# Test 1: Feature install script exists
log_info "Test: Install script exists"
if docker run --rm "$TEST_IMAGE" test -f /tmp/features/$FEATURE_ID/install.sh 2>/dev/null; then
  log_pass "Install script exists"
  ((TESTS_PASSED++)) || true
else
  log_fail "Install script not found"
  ((TESTS_FAILED++)) || true
fi

# Test 2: Run postInstallCheck if defined
if [ -n "$POST_INSTALL_CMD" ]; then
  log_info "Test: postInstallCheck command"
  if output=$(docker run --rm -u jovyan "$TEST_IMAGE" bash -lc "$POST_INSTALL_CMD" 2>&1); then
    log_pass "postInstallCheck passed"
    ((TESTS_PASSED++)) || true
    [ "$VERBOSE" = true ] && echo "  Output: $output"
  else
    log_fail "postInstallCheck failed"
    ((TESTS_FAILED++)) || true
    [ "$VERBOSE" = true ] && echo "  Error: $output"
  fi
else
  log_warn "No postInstallCheck defined in feature.json"
fi

# Test 3: Verify provided tools/packages exist
if [ -n "$PROVIDES" ]; then
  echo
  log_info "Checking provided tools/packages..."
  for tool in $PROVIDES; do
    run_test "Tool '$tool' available" "command -v $tool >/dev/null 2>&1 || which $tool >/dev/null 2>&1" "jovyan"
  done
fi

# Test 4: Check feature marker file
log_info "Test: Feature marked as installed"
if docker run --rm "$TEST_IMAGE" test -f "/opt/.features/$FEATURE_ID" 2>/dev/null; then
  log_pass "Feature marker exists"
  ((TESTS_PASSED++)) || true
else
  log_warn "Feature marker not found (not all features use markers)"
fi

# Test 5: User permissions
log_info "Test: User can write to home directory"
if docker run --rm -u jovyan "$TEST_IMAGE" bash -c "touch /home/jovyan/.test-write && rm /home/jovyan/.test-write" 2>/dev/null; then
  log_pass "User permissions correct"
  ((TESTS_PASSED++)) || true
else
  log_fail "User cannot write to home directory"
  ((TESTS_FAILED++)) || true
fi

# Summary
echo
echo "===================================================================="
echo "Test Summary"
echo "===================================================================="
echo "Feature: $FEATURE_ID"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"
echo "===================================================================="

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ Some tests failed${NC}"
  exit 1
fi
