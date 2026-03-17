#!/usr/bin/env bash
# NemoClaw — DGX Spark health check
#
# Validates that all components are running correctly on Spark.
# Run after setup to confirm everything is operational.
#
# Usage:
#   bash scripts/spark-health.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1"
  local result="$2"
  if [ "$result" = "pass" ]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  elif [ "$result" = "warn" ]; then
    echo -e "  ${YELLOW}~${NC} $label"
    WARN=$((WARN + 1))
  else
    echo -e "  ${RED}✗${NC} $label"
    FAIL=$((FAIL + 1))
  fi
}

echo -e "${BOLD}NemoClaw DGX Spark Health Check${NC}"
echo ""

# ── Hardware ────────────────────────────────────────────────────
echo -e "${BOLD}Hardware${NC}"

# Architecture
if [ "$(uname -m)" = "aarch64" ]; then
  check "ARM64 architecture" "pass"
else
  check "ARM64 architecture (got: $(uname -m))" "warn"
fi

# GB10 detection
if command -v nvidia-smi > /dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo "")
  if echo "$GPU_NAME" | grep -qi "GB10"; then
    check "GB10 Grace Blackwell detected" "pass"
  else
    check "GB10 Grace Blackwell (got: ${GPU_NAME:-none})" "warn"
  fi
else
  check "nvidia-smi available" "fail"
fi

# Memory
TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
if [ "$TOTAL_MEM_MB" -ge 120000 ]; then
  check "Unified memory: ${TOTAL_MEM_MB} MB (~$((TOTAL_MEM_MB / 1024)) GB)" "pass"
elif [ "$TOTAL_MEM_MB" -gt 0 ]; then
  check "Memory: ${TOTAL_MEM_MB} MB (expected ~128 GB for Spark)" "warn"
else
  check "Memory detection" "fail"
fi

echo ""

# ── Docker ──────────────────────────────────────────────────────
echo -e "${BOLD}Docker${NC}"

# Docker running
if docker info > /dev/null 2>&1; then
  check "Docker daemon running" "pass"
else
  check "Docker daemon running" "fail"
fi

# cgroup v2
CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "unknown")
if [ "$CGROUP_TYPE" = "cgroup2fs" ]; then
  check "cgroup v2 active" "pass"
else
  check "cgroup v2 (got: $CGROUP_TYPE)" "warn"
fi

# cgroupns=host
if [ -f /etc/docker/daemon.json ]; then
  CGROUPNS=$(python3 -c "import json; print(json.load(open('/etc/docker/daemon.json')).get('default-cgroupns-mode',''))" 2>/dev/null || echo "")
  if [ "$CGROUPNS" = "host" ]; then
    check "Docker cgroupns=host configured" "pass"
  else
    check "Docker cgroupns=host (not set)" "fail"
  fi
else
  check "Docker daemon.json exists" "fail"
fi

# NVIDIA Container Toolkit
if command -v nvidia-ctk > /dev/null 2>&1; then
  check "NVIDIA Container Toolkit installed" "pass"
else
  check "NVIDIA Container Toolkit" "warn"
fi

echo ""

# ── OpenShell ───────────────────────────────────────────────────
echo -e "${BOLD}OpenShell${NC}"

if command -v openshell > /dev/null 2>&1; then
  check "openshell CLI installed" "pass"

  # Gateway status
  if openshell status 2>&1 | grep -q "Connected"; then
    check "OpenShell gateway connected" "pass"
  else
    check "OpenShell gateway connected" "fail"
  fi
else
  check "openshell CLI installed" "fail"
fi

echo ""

# ── Inference ───────────────────────────────────────────────────
echo -e "${BOLD}Inference${NC}"

# Local vLLM
if curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
  RUNNING_MODEL=$(curl -s http://localhost:8000/v1/models | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else 'unknown')" 2>/dev/null || echo "unknown")
  check "Local vLLM running (model: $RUNNING_MODEL)" "pass"
else
  check "Local vLLM on :8000 (not running)" "warn"
fi

# NVIDIA Cloud API
if [ -n "${NVIDIA_API_KEY:-}" ]; then
  check "NVIDIA_API_KEY set" "pass"

  CLOUD_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $NVIDIA_API_KEY" \
    https://integrate.api.nvidia.com/v1/models 2>/dev/null || echo "000")
  if [ "$CLOUD_STATUS" = "200" ]; then
    check "NVIDIA Cloud API reachable" "pass"
  else
    check "NVIDIA Cloud API (HTTP $CLOUD_STATUS)" "warn"
  fi
else
  check "NVIDIA_API_KEY set" "warn"
fi

echo ""

# ── NemoClaw Sandbox ────────────────────────────────────────────
echo -e "${BOLD}NemoClaw Sandbox${NC}"

if command -v openshell > /dev/null 2>&1; then
  SANDBOX_STATUS=$(openshell sandbox status openclaw 2>&1 || echo "not found")
  if echo "$SANDBOX_STATUS" | grep -qi "running\|ready"; then
    check "Sandbox 'openclaw' running" "pass"
  elif echo "$SANDBOX_STATUS" | grep -qi "stopped\|created"; then
    check "Sandbox 'openclaw' exists (not running)" "warn"
  else
    check "Sandbox 'openclaw' (not found)" "warn"
  fi
fi

# Dashboard port
if curl -s http://127.0.0.1:18789/ > /dev/null 2>&1; then
  check "Dashboard UI on :18789" "pass"
else
  check "Dashboard UI on :18789 (not responding)" "warn"
fi

echo ""

# ── Summary ─────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL + WARN))
echo -e "${BOLD}Summary: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC} (${TOTAL} checks)"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Fix failures before running NemoClaw. See docs/deployment/dgx-spark.md"
  exit 1
fi
