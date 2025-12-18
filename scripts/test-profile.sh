#!/usr/bin/env bash
# Smoke test for built profile images
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_info() { echo -e "${YELLOW}→${NC} $1"; }

# Parse arguments
IMAGE="$1"
PROFILE="${2:-unknown}"

if [ -z "${IMAGE}" ]; then
  echo "Usage: $0 <image> [profile-name]"
  echo "Example: $0 ghcr.io/ebpro/jupyter-base:quarto-lecture-dev-java-25-develop 20-02-quarto-lecture-dev-java-25"
  exit 1
fi

log_info "Testing image: ${IMAGE}"
log_info "Profile: ${PROFILE}"
echo

FAILED=0
PASSED=0

# Helper to run test
run_test() {
  local name="$1"
  local cmd="$2"
  local user="${3:-jovyan}"
  local use_login="${4:-false}"
  
  log_info "Testing: ${name}"
  
  local docker_cmd
  if [ "${use_login}" = "true" ]; then
    # Use login shell to source profile
    docker_cmd="docker run --rm -u ${user} ${IMAGE} zsh -lc '${cmd}'"
  else
    docker_cmd="docker run --rm -u ${user} ${IMAGE} bash -c '${cmd}'"
  fi
  
  if eval "${docker_cmd}" >/dev/null 2>&1; then
    log_pass "${name}"
    ((PASSED++)) || true
  else
    log_fail "${name}"
    ((FAILED++)) || true
  fi
}

# Core tests (all profiles)
echo "=== Core Tests ==="
run_test "User jovyan exists" "id jovyan"
run_test "Home directory exists" "test -d /home/jovyan"
run_test "Zsh is installed" "which zsh"
run_test "Basic tools available" "which git curl jq"

# Detect what features are installed based on profile name or common paths
echo
echo "=== Feature Tests ==="

# Python/Conda tests (test via full path since conda isn't auto-activated)
if docker run --rm "${IMAGE}" test -d /home/jovyan/miniforge3 2>/dev/null; then
  run_test "Conda is installed" "test -x /home/jovyan/miniforge3/bin/conda"
  run_test "Python from conda is available" "test -x /home/jovyan/miniforge3/bin/python"
  run_test "Mamba is installed" "test -x /home/jovyan/miniforge3/bin/mamba"
fi

# Jupyter tests
if docker run --rm "${IMAGE}" which jupyter 2>/dev/null; then
  run_test "Jupyter is installed" "jupyter --version"
  run_test "JupyterLab is installed" "jupyter lab --version"
  run_test "Python kernel is registered" "jupyter kernelspec list | grep python3"
fi

# Quarto tests
if docker run --rm "${IMAGE}" which quarto 2>/dev/null; then
  run_test "Quarto is installed" "quarto --version"
  run_test "Quarto finds Jupyter" "quarto check 2>&1 | grep -q 'Jupyter:' && echo ok"
fi

# Java tests (test via full path since SDKMAN needs sourcing)
if docker run --rm "${IMAGE}" test -d /home/jovyan/.sdkman 2>/dev/null; then
  run_test "SDKMAN is installed" "test -d /home/jovyan/.sdkman"
  run_test "Java is installed" "test -d /home/jovyan/.sdkman/candidates/java/current"
  # Maven and Gradle are optional
  if docker run --rm "${IMAGE}" test -d /home/jovyan/.sdkman/candidates/maven 2>/dev/null; then
    run_test "Maven is installed" "test -d /home/jovyan/.sdkman/candidates/maven/current" || true
  fi
  if docker run --rm "${IMAGE}" test -d /home/jovyan/.sdkman/candidates/gradle 2>/dev/null; then
    run_test "Gradle is installed" "test -d /home/jovyan/.sdkman/candidates/gradle/current" || true
  fi
fi

# Java kernel tests (only if both Java and Jupyter present)
if docker run --rm "${IMAGE}" which jupyter 2>/dev/null && \
   docker run --rm "${IMAGE}" which java 2>/dev/null; then
  run_test "Java kernel is registered" "jupyter kernelspec list | grep java" || true
fi

# Node tests
if docker run --rm "${IMAGE}" which node 2>/dev/null; then
  run_test "Node.js is installed" "node --version"
  run_test "npm is installed" "npm --version"
fi

# Container tools
if docker run --rm "${IMAGE}" which docker 2>/dev/null; then
  run_test "Docker CLI is available" "docker --version"
fi

if docker run --rm "${IMAGE}" which kubectl 2>/dev/null; then
  run_test "kubectl is available" "kubectl version --client"
  run_test "helm is available" "which helm" || true
fi

# LaTeX tests
if docker run --rm "${IMAGE}" which pdflatex 2>/dev/null; then
  run_test "LaTeX is installed" "pdflatex --version"
fi

# Git tools
if docker run --rm "${IMAGE}" which gh 2>/dev/null; then
  run_test "GitHub CLI is installed" "gh --version"
fi

if docker run --rm "${IMAGE}" which git-lfs 2>/dev/null; then
  run_test "Git LFS is installed" "git-lfs --version"
fi

# Summary
echo
echo "================================"
echo "Test Results:"
echo "  Passed: ${PASSED}"
echo "  Failed: ${FAILED}"
echo "================================"

if [ ${FAILED} -eq 0 ]; then
  log_pass "All tests passed!"
  exit 0
else
  log_fail "${FAILED} test(s) failed"
  exit 1
fi
